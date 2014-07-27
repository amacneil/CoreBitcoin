// Oleg Andreev <oleganza@gmail.com>

#import "BTCData.h"
#import <CommonCrypto/CommonCrypto.h>
#if BTCDataRequiresOpenSSL
#include <openssl/ripemd.h>
#include <openssl/evp.h>
#endif

static const unsigned char _BTCZeroString256[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};

// Use this subclass to make sure data is zeroed
@implementation BTCMutableDataZeroedOnDealloc : NSMutableData
+ (instancetype) dataWithData:(NSData *)data
{
    if (!data) return nil;
    
    return [NSMutableData dataWithData:data];
    
//    BTCMutableDataZeroedOnDealloc* result = [[BTCMutableDataZeroedOnDealloc alloc] initWithBytes:data.bytes length:data.length];
    BTCMutableDataZeroedOnDealloc* result = [[BTCMutableDataZeroedOnDealloc alloc] init];
    [result appendBytes:data.bytes length:data.length];
    return result;
}
- (void) dealloc
{
    [self resetBytesInRange:NSMakeRange(0, self.length)];
}
@end


// This is designed to be not optimized out by compiler like memset
void *BTCSecureMemset(void *v, unsigned char c, size_t n)
{
    if (!v) return v;
    volatile unsigned char *p = v;
    while (n--)
        *p++ = c;
    
    return v;
}

void BTCSecureClearCString(char *s)
{
    if (!s) return;
    BTCSecureMemset(s, 0, strlen(s));
}

void *BTCCreateRandomBytesOfLength(size_t length)
{
    FILE *fp = fopen("/dev/random", "r");
    if (!fp)
    {
        NSLog(@"NSData+BTC: cannot fopen /dev/random");
        exit(-1);
        return NULL;
    }
    char* bytes = (char*)malloc(length);
    for (int i = 0; i < length; i++)
    {
        char c = fgetc(fp);
        bytes[i] = c;
    }
    
    fclose(fp);
    return bytes;
}

// Returns data with securely random bytes of the specified length. Uses /dev/random.
NSData* BTCRandomDataWithLength(NSUInteger length)
{
    void *bytes = BTCCreateRandomBytesOfLength(length);
    if (!bytes) return nil;
    return [[NSData alloc] initWithBytesNoCopy:bytes length:length];
}

// Returns data produced by flipping the coin as proposed by Dan Kaminsky:
// https://gist.github.com/PaulCapestany/6148566

static inline int BTCCoinFlip()
{
    __block int n = 0;
    //int c = 0;
    dispatch_time_t then = dispatch_time(DISPATCH_TIME_NOW, 999000ull);

    // We need to increase variance of number of flips, so we force system to schedule some threads
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        while (dispatch_time(DISPATCH_TIME_NOW, 0) <= then)
        {
            n = !n;
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (dispatch_time(DISPATCH_TIME_NOW, 0) <= then)
        {
            n = !n;
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (dispatch_time(DISPATCH_TIME_NOW, 0) <= then)
        {
            n = !n;
        }
    });

    while (dispatch_time(DISPATCH_TIME_NOW, 0) <= then)
    {
        //c++;
        n = !n; // flipping the coin
    }
    //NSLog(@"Flips: %d", c);
    return n;
}

// Simple Von Neumann debiasing - throwing away two flips that return the same value.
static inline int BTCFairCoinFlip()
{
    while(1)
    {
        int a = BTCCoinFlip();
        if (a != BTCCoinFlip())
        {
            return a;
        }
    }
}

NSData* BTCCoinFlipDataWithLength(NSUInteger length)
{
    NSMutableData* data = [NSMutableData dataWithLength:length];
    unsigned char* bytes = data.mutableBytes;
    for (int i = 0; i < length; i++)
    {
        unsigned char byte = 0;
        int bits = 8;
        while(bits--)
        {
            byte <<= 1;
            byte |= BTCFairCoinFlip();
        }
        bytes[i] = byte;
    }
    return data;
}


// Creates data with zero-terminated string in UTF-8 encoding.
NSData* BTCDataWithUTF8String(const char* utf8string)
{
    return [[NSData alloc] initWithBytes:utf8string length:strlen(utf8string)];
}

// Init with hex string (lower- or uppercase, with optional 0x prefix)
NSData* BTCDataWithHexString(NSString* hexString)
{
    return BTCDataWithHexCString([hexString cStringUsingEncoding:NSASCIIStringEncoding]);
}

// Init with zero-terminated hex string (lower- or uppercase, with optional 0x prefix)
NSData* BTCDataWithHexCString(const char* hexCString)
{
    if (hexCString == NULL) return nil;
    
    const unsigned char *psz = (const unsigned char*)hexCString;
    
    while (isspace(*psz)) psz++;
    
    // Skip optional 0x prefix
    if (psz[0] == '0' && tolower(psz[1]) == 'x') psz += 2;
        
        while (isspace(*psz)) psz++;
    
    size_t len = strlen((const char*)psz);
    
    // If the string is not full number of bytes (each byte 2 hex characters), return nil.
    if (len % 2 != 0) return nil;
    
    unsigned char* buf = (unsigned char*)malloc(len/2);
    
    static const signed char digits[256] = {
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, -1, -1, -1, -1, -1, -1,
        -1,0xa,0xb,0xc,0xd,0xe,0xf, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1,0xa,0xb,0xc,0xd,0xe,0xf, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
    };
    
    unsigned char* bufpointer = buf;
    
    while (1)
    {
        unsigned char c1 = (unsigned char)*psz++;
        signed char n1 = digits[c1];
        if (n1 == (signed char)-1) break; // break when null-terminator is hit
        
        unsigned char c2 = (unsigned char)*psz++;
        signed char n2 = digits[c2];
        if (n2 == (signed char)-1) break; // break when null-terminator is hit
        
        *bufpointer = (unsigned char)((n1 << 4) | n2);
        bufpointer++;
    }
    
    return [[NSData alloc] initWithBytesNoCopy:buf length:len/2];
}

NSData* BTCReversedData(NSData* data)
{
    return BTCReversedMutableData(data);
}

NSMutableData* BTCReversedMutableData(NSData* data)
{
    if (!data) return nil;
    NSMutableData* md = [NSMutableData dataWithData:data];
    BTCDataReverse(md);
    return md;
}

void BTCReverseBytesLength(void* bytes, NSUInteger length)
{
    // K&R
    if (length <= 1) return;
    unsigned char* buf = bytes;
    unsigned char byte;
    NSUInteger i, j;
    for (i = 0, j = length - 1; i < j; i++, j--)
    {
        byte = buf[i];
        buf[i] = buf[j];
        buf[j] = byte;
    }
}

// Reverses byte order in the internal buffer of mutable data object.
void BTCDataReverse(NSMutableData* self)
{
    BTCReverseBytesLength(self.mutableBytes, self.length);
}

// Clears contents of the data to prevent leaks through swapping or buffer-overflow attacks.
void BTCDataClear(NSMutableData* self)
{
    [self resetBytesInRange:NSMakeRange(0, self.length)];
}

NSMutableData* BTCSHA1(NSData* data)
{
    if (!data) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([data bytes], (CC_LONG)[data length], digest);
    return [NSMutableData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
}

NSMutableData* BTCSHA256(NSData* data)
{
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    return [NSMutableData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

NSMutableData* BTCSHA256Concat(NSData* data1, NSData* data2)
{
    if (!data1 || !data2) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, [data1 bytes], (CC_LONG)[data1 length]);
    CC_SHA256_Update(&ctx, [data2 bytes], (CC_LONG)[data2 length]);
    CC_SHA256_Final(digest, &ctx);
    return [NSMutableData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

NSMutableData* BTCHash256(NSData* data)
{
    if (!data) return nil;
    unsigned char digest1[CC_SHA256_DIGEST_LENGTH];
    unsigned char digest2[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest1);
    CC_SHA256(digest1, CC_SHA256_DIGEST_LENGTH, digest2);
    NSMutableData* result = [NSMutableData dataWithBytes:digest2 length:CC_SHA256_DIGEST_LENGTH];
    BTCSecureMemset(digest1, 0, CC_SHA256_DIGEST_LENGTH);
    BTCSecureMemset(digest2, 0, CC_SHA256_DIGEST_LENGTH);
    return result;
}

NSMutableData* BTCHash256Concat(NSData* data1, NSData* data2)
{
    if (!data1 || !data2) return nil;
    
    unsigned char digest1[CC_SHA256_DIGEST_LENGTH];
    unsigned char digest2[CC_SHA256_DIGEST_LENGTH];
    
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, [data1 bytes], (CC_LONG)[data1 length]);
    CC_SHA256_Update(&ctx, [data2 bytes], (CC_LONG)[data2 length]);
    CC_SHA256_Final(digest1, &ctx);
    CC_SHA256(digest1, CC_SHA256_DIGEST_LENGTH, digest2);
    
    NSMutableData* result = [NSMutableData dataWithBytes:digest2 length:CC_SHA256_DIGEST_LENGTH];
    BTCSecureMemset(digest1, 0, CC_SHA256_DIGEST_LENGTH);
    BTCSecureMemset(digest2, 0, CC_SHA256_DIGEST_LENGTH);
    return result;
}

NSMutableData* BTCZero160()
{
    return [NSMutableData dataWithBytes:_BTCZeroString256 length:20];
}

NSMutableData* BTCZero256()
{
    return [NSMutableData dataWithBytes:_BTCZeroString256 length:32];
}

const unsigned char* BTCZeroString256()
{
    return _BTCZeroString256;
}

NSMutableData* BTCHMACSHA256(NSData* key, NSData* data)
{
    if (!key) return nil;
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, digest);
    NSMutableData* result = [NSMutableData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    BTCSecureMemset(digest, 0, CC_SHA256_DIGEST_LENGTH);
    return result;
}

NSMutableData* BTCHMACSHA512(NSData* key, NSData* data)
{
    if (!key) return nil;
    if (!data) return nil;
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA512, key.bytes, key.length, data.bytes, data.length, digest);
    NSMutableData* result = [NSMutableData dataWithBytes:digest length:CC_SHA512_DIGEST_LENGTH];
    BTCSecureMemset(digest, 0, CC_SHA512_DIGEST_LENGTH);
    return result;
}

#if BTCDataRequiresOpenSSL

NSMutableData* BTCRIPEMD160(NSData* data)
{
    if (!data) return nil;
    unsigned char digest[RIPEMD160_DIGEST_LENGTH];
    RIPEMD160([data bytes], (size_t)[data length], digest);
    return [NSMutableData dataWithBytes:digest length:RIPEMD160_DIGEST_LENGTH];
}

NSMutableData* BTCHash160(NSData* data)
{
    if (!data) return nil;
    unsigned char digest1[CC_SHA256_DIGEST_LENGTH];
    unsigned char digest2[RIPEMD160_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest1);
    RIPEMD160(digest1, CC_SHA256_DIGEST_LENGTH, digest2);
    NSMutableData* result = [NSMutableData dataWithBytes:digest2 length:RIPEMD160_DIGEST_LENGTH];
    BTCSecureMemset(digest1, 0, CC_SHA256_DIGEST_LENGTH);
    BTCSecureMemset(digest2, 0, RIPEMD160_DIGEST_LENGTH);
    return result;
}

#endif



NSString* BTCHexStringFromDataWithFormat(NSData* data, const char* format)
{
    if (!data) return nil;
    
    NSUInteger length = data.length;
    if (length == 0) return @"";
    
    NSMutableData* resultdata = [NSMutableData dataWithLength:length * 2];
    char *dest = resultdata.mutableBytes;
    unsigned const char *src = data.bytes;
    for (int i = 0; i < length; ++i)
    {
        sprintf(dest + i*2, format, (unsigned int)(src[i]));
    }
    return [[NSString alloc] initWithData:resultdata encoding:NSASCIIStringEncoding];
}

NSString* BTCHexStringFromData(NSData* data)
{
    return BTCHexStringFromDataWithFormat(data, "%02x");
}

NSString* BTCUppercaseHexStringFromData(NSData* data)
{
    return BTCHexStringFromDataWithFormat(data, "%02X");
}

// Hashes input with salt using specified number of rounds and the minimum amount of memory (rounded up to a whole number of 256-bit blocks).
// Actual number of hash function computations is a number of rounds multiplied by a number of 256-bit blocks.
// So rounds=1 for 256 Mb of memory would mean 8M hash function calculations (8M blocks by 32 byte to form 256 Mb total).
// Uses SHA256 as an internal hash function.
// Password and salt are hashed before being placed in the first block.
// The whole memory region is hashed after all rounds to generate the result.
// Based on proposal by Sergio Demian Lerner http://bitslog.files.wordpress.com/2013/12/memohash-v0-3.pdf
// Returns a mutable data, so you can cleanup the memory when needed.
NSMutableData* BTCMemoryHardKDF256(NSData* password, NSData* salt, unsigned int rounds, unsigned int numberOfBytes)
{
    const unsigned int blockSize = CC_SHA256_DIGEST_LENGTH;
    
    // Will be used for intermediate hash computation
    unsigned char block[blockSize];
    
    // Context for computing hashes.
    CC_SHA256_CTX ctx;
    
    // Round up the required memory to integral number of blocks
    unsigned int numberOfBlocks = numberOfBytes / blockSize;
    if (numberOfBytes % blockSize) numberOfBlocks++;
    numberOfBytes = numberOfBlocks * blockSize;
    
    // Make sure we have at least 1 round
    rounds = rounds ? rounds : 1;
    
    // Allocate the required memory
    NSMutableData* space = [NSMutableData dataWithLength:numberOfBytes];
    unsigned char* spaceBytes = space.mutableBytes;
    
    // Hash the password with the salt to produce the initial seed
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, password.bytes, (CC_LONG)password.length);
    CC_SHA256_Update(&ctx, salt.bytes, (CC_LONG)salt.length);
    CC_SHA256_Final(block, &ctx);

    // Set the seed to the first block
    memcpy(spaceBytes, block, blockSize);
    
    // Produce a chain of hashes to fill the memory with initial data
    for (unsigned int  i = 1; i < numberOfBlocks; i++)
    {
        // Put a hash of the previous block into the next block.
        CC_SHA256_Init(&ctx);
        CC_SHA256_Update(&ctx, spaceBytes + (i - 1) * blockSize, blockSize);
        CC_SHA256_Final(block, &ctx);
        memcpy(spaceBytes + i * blockSize, block, blockSize);
    }
    
    // Each round consists of hashing the entire space block by block.
    for (unsigned int r = 0; r < rounds; r++)
    {
        // For each block, update it with the hash of the previous block
        // mixed with the randomly shifted block around the current one.
        for (unsigned int b = 0; b < numberOfBlocks; b++)
        {
            unsigned int prevb = (numberOfBlocks + b - 1) % numberOfBlocks;
            
            // Interpret the previous block as an integer to provide some randomness to memory location.
            // This reduces potential for memory access optimization.
            // We are simplifying a task here by simply taking first 64 bits instead of full 256 bits.
            // In theory it may give some room for optimization, but it would be equivalent to a slightly more efficient prediction of the next block,
            // which does not remove the need to store all blocks in memory anyway.
            // Also, this optimization would be meaningless if the amount of memory is a power of two. E.g. 16, 32, 64 or 128 Mb.
            unsigned long long offset = (*((unsigned long long*)(spaceBytes + prevb * blockSize))) % (numberOfBlocks - 1); // (N-1) is taken to exclude prevb block.
            
            // Calculate actual index relative to the current block.
            offset = (b + offset) % numberOfBlocks;
            
            // Mix previous block with a random one.
            CC_SHA256_Init(&ctx);
            CC_SHA256_Update(&ctx, spaceBytes + prevb * blockSize, blockSize); // mix previous block
            CC_SHA256_Update(&ctx, spaceBytes + offset * blockSize, blockSize); // mix random block around the current one
            CC_SHA256_Final(block, &ctx);
            memcpy(spaceBytes + b * blockSize, block, blockSize);
        }
    }
    
    // Hash the whole space to arrive at a final derived key.
    CC_SHA256_Init(&ctx);
    for (unsigned int b = 0; b < numberOfBlocks; b++)
    {
        CC_SHA256_Update(&ctx, spaceBytes + b * blockSize, blockSize);
    }
    CC_SHA256_Final(block, &ctx);
    
    NSMutableData* derivedKey = [NSMutableData dataWithBytes:block length:blockSize];
    
    // Clean all the buffers to leave no traces of sensitive data
    BTCSecureMemset(&ctx, 0, sizeof(ctx));
    BTCSecureMemset(block, 0, blockSize);
    BTCSecureMemset(spaceBytes, 0, numberOfBytes);
    
    return derivedKey;
}



// Hashes input with salt using specified number of rounds and the minimum amount of memory (rounded up to a whole number of 128-bit blocks)
NSMutableData* BTCMemoryHardAESKDF(NSData* password, NSData* salt, unsigned int rounds, unsigned int numberOfBytes)
{
    // The idea is to use a highly optimized AES implementation in CBC mode to quickly transform a lot of memory.
    // For the first round, a SHA256(password+salt) is used as AES key and SHA256(key+salt) is used as Initialization Vector (IV).
    // After each round, last 256 bits of space are hashed with IV to produce new IV for the next round. Key remains the same.
    // After the final round, last 256 bits are hashed with the AES key to arrive at the resulting key.
    // This is based on proposal by Sergio Demian Lerner http://bitslog.files.wordpress.com/2013/12/memohash-v0-3.pdf
    // More specifically, on his SeqMemoHash where he shows that when number of rounds is equal to number of memory blocks,
    // hash function is strictly memory hard: any less memory than N blocks will make computation impossible.
    // If less than N number of rounds is used, execution time grows exponentially with number of rounds, thus quickly making memory/time tradeoff
    // increasingly towards choosing an optimal amount of memory.
    
    // 1 round can be optimized to using just one small block of memory for block cipher operation (n = 1).
    // 2 rounds can reduce memory to 2 blocks, but the 2nd round would need recomputation of the 1st round in parallel (n = 1 + (1 + 1) = 3).
    // 3 rounds can reduce memory to 3 blocks, but the 3rd round would need recomputation of the 2nd round in parallel (n = 3 + (1 + 3) = 7).
    // k-th round can reduce memory to k blocks, the k-th round would need recomputation of the (k-1)-th round in parallel (n(k) = n(k-1) + (1 + n(k-1)) = 1 + 2*n(k-1))
    // Ultimately, k rounds with N blocks of memory would need at minimum k blocks of memory at expense of (2^k - 1) rounds.
    
    const unsigned int digestSize = CC_SHA256_DIGEST_LENGTH;
    const unsigned int blockSize = 128/8;

    // Round up the required memory to integral number of blocks
    {
        if (numberOfBytes < digestSize) numberOfBytes = digestSize;
        unsigned int numberOfBlocks = numberOfBytes / blockSize;
        if (numberOfBytes % blockSize) numberOfBlocks++;
        numberOfBytes = numberOfBlocks * blockSize;
    }
    
    // Make sure we have at least 3 rounds (1 round would be equivalent to using just 32 bytes of memory; 2 rounds would become 3 rounds if memory was reduced to 32 bytes)
    if (rounds < 3) rounds = 3;

    // Will be used for intermediate hash computation
    unsigned char key[digestSize];
    unsigned char iv[digestSize];

    // Context for computing hashes.
    CC_SHA256_CTX ctx;
    
    // Allocate the required memory
    NSMutableData* space = [NSMutableData dataWithLength:numberOfBytes + blockSize]; // extra block for the cipher.
    unsigned char* spaceBytes = space.mutableBytes;
    
    // key = SHA256(password + salt)
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, password.bytes, (CC_LONG)password.length);
    CC_SHA256_Update(&ctx, salt.bytes, (CC_LONG)salt.length);
    CC_SHA256_Final(key, &ctx);
    
    // iv = SHA256(key + salt)
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, key, (CC_LONG)digestSize);
    CC_SHA256_Update(&ctx, salt.bytes, (CC_LONG)salt.length);
    CC_SHA256_Final(iv, &ctx);
    
    // Set the space to 1010101010...
    memset(spaceBytes, (1 + 4 + 16 + 64), numberOfBytes);
    
    // Each round consists of encrypting the entire space using AES-CBC
    BOOL failed = NO;
    for (unsigned int r = 0; r < rounds; r++)
    {
        if (1) // Apple implementation - slightly faster than OpenSSL one.
        {
            size_t dataOutMoved = 0;
            CCCryptorStatus cryptstatus = CCCrypt(
                                                  kCCEncrypt,                  // CCOperation op,         /* kCCEncrypt, kCCDecrypt */
                                                  kCCAlgorithmAES,             // CCAlgorithm alg,        /* kCCAlgorithmAES128, etc. */
                                                  kCCOptionPKCS7Padding,       // CCOptions options,      /* kCCOptionPKCS7Padding, etc. */
                                                  key,                         // const void *key,
                                                  digestSize,                  // size_t keyLength,
                                                  iv,                          // const void *iv,         /* optional initialization vector */
                                                  spaceBytes,                  // const void *dataIn,     /* optional per op and alg */
                                                  numberOfBytes,               // size_t dataInLength,
                                                  spaceBytes,                  // void *dataOut,          /* data RETURNED here */
                                                  numberOfBytes + blockSize,   // size_t dataOutAvailable,
                                                  &dataOutMoved                // size_t *dataOutMoved
                                                  );
            
            if (cryptstatus != kCCSuccess || dataOutMoved != (numberOfBytes + blockSize))
            {
                failed = YES;
                break;
            }
        }
        else // OpenSSL implementation
        {
            EVP_CIPHER_CTX evpctx;
            int outlen1, outlen2;
            
            EVP_EncryptInit(&evpctx, EVP_aes_256_cbc(), key, iv);
            EVP_EncryptUpdate(&evpctx, spaceBytes, &outlen1, spaceBytes, (int)numberOfBytes);
            EVP_EncryptFinal(&evpctx, spaceBytes + outlen1, &outlen2);
            
            if (outlen1 != numberOfBytes || outlen2 != blockSize)
            {
                failed = YES;
                break;
            }
        }

        // iv2 = SHA256(iv1 + tail)
        CC_SHA256_Init(&ctx);
        CC_SHA256_Update(&ctx, iv, digestSize); // mix the current IV.
        CC_SHA256_Update(&ctx, spaceBytes + numberOfBytes - digestSize, digestSize); // mix in last 256 bits.
        CC_SHA256_Final(iv, &ctx);
    }
    
    NSMutableData* derivedKey = nil;
    
    if (!failed)
    {
        // derivedKey = SHA256(key + tail)
        CC_SHA256_Init(&ctx);
        CC_SHA256_Update(&ctx, key, digestSize); // mix the current key.
        CC_SHA256_Update(&ctx, spaceBytes + numberOfBytes - digestSize, digestSize); // mix in last 256 bits.
        CC_SHA256_Final(key, &ctx);

        derivedKey = [NSMutableData dataWithBytes:key length:digestSize];
    }
    
    // Clean all the buffers to leave no traces of sensitive data
    BTCSecureMemset(&ctx,       0, sizeof(ctx));
    BTCSecureMemset(key,        0, digestSize);
    BTCSecureMemset(iv,         0, digestSize);
    BTCSecureMemset(spaceBytes, 0, numberOfBytes + blockSize);
    
    return derivedKey;

}





// Probabilistic memory-hard KDF with 256-bit output and only one difficulty parameter - amount of memory.
// Actual amount of memory is rounded to a whole number of 256-bit blocks.
// Uses SHA512 as internal hash function.
// Computational time is proportional to amount of memory.
// Brutefore with half the memory raises amount of hash computations quadratically.
NSMutableData* BTCJerk256(NSData* password, NSData* salt, unsigned int numberOfBytes)
{
    @autoreleasepool {
        
        const unsigned int blockSize = CC_SHA512_DIGEST_LENGTH / 2;
        
        // Round up the required memory to integral number of blocks.
        // Minimum size is 512 bits.
        {
            if (numberOfBytes < blockSize*2) numberOfBytes = blockSize*2;
            unsigned int numberOfBlocks = numberOfBytes / blockSize;
            if (numberOfBytes % blockSize) numberOfBlocks++;
            numberOfBytes = numberOfBlocks * blockSize;
        }
        
        // Context for computing hashes.
        CC_SHA512_CTX ctx;
        
        // Allocate the required memory
        NSMutableData* space = [NSMutableData dataWithLength:numberOfBytes + blockSize]; // a bit of extra memory for temporary storage of SHA512
        unsigned char* spaceBytes = space.mutableBytes;
        
        // Initial two blocks = SHA512(password + salt)
        CC_SHA512_Init(&ctx);
        CC_SHA512_Update(&ctx, password.bytes, (CC_LONG)password.length);
        CC_SHA512_Update(&ctx, salt.bytes, (CC_LONG)salt.length);
        CC_SHA512_Final(spaceBytes, &ctx);
        
        // Take first 256 bits as a key to mix in during hashing below.
        NSData* key = [NSData dataWithBytes:spaceBytes length:blockSize];
        const unsigned char* keyBytes = key.bytes;
        
        // At each step we try reinforce memory requirement while spending as little time as possible.
        // Making each step fast allows us to require more memory in the same amount of time.
        // Some applications wouldn't like to waste more than 100 ms on KDF, some are okay to spend 5 sec.
        // Yet, the more memory we can use in that period of time, the better.
        
        // We start with just 2 blocks of data. It's pointless to waste time filling in the whole space.
        // It's also pointless to use any of the remaining space. The only source of entropy we have is in the very beginning.
        // We use the initial state to produce the next block and at the same time we pseudo-randomly mutate that space to force attacker to keep the result around.
        
        // On step two we will have slightly more material, so we'll use that. As we go further in the space,
        // amount of generated data grows, but the amount of computations per step is the same.
        
        // When we arrive at the end, we simply take the last 256 bits as a result.
        
        for (unsigned long i = 2*blockSize; i < numberOfBytes; i += blockSize)
        {
            // A = previous block (filled).
            // B = next block (empty).
            // A is composed of little-endian 64-bit numbers: {A1, A2, A3, A4}.
            // 64-bit chunk C1 will be pointed at by A1 mod (i - 7).
            // 64-bit chunk C2 will be pointed at by (C1 ^ A2) mod (i - 7).
            // 64-bit chunk C3 will be pointed at by (C2 ^ A3) mod (i - 7).
            // Compute hash H = SHA512(C1 ++ C2 ++ C3 ++ A4 ++ key) = {R, H1, H2, H3, H4}, where R - 256-bit block and H1,H2,H3,H4 are 64-bit numbers.
            // Copy H1 to C1, H2 to C2, H3 to C3 and H4 to A1.
            // Copy R into B.
            // Increase i by the block size and repeat.
            // Note that A1 is completely replaced by a hash, so it's hard to quickly find a chain of blocks C1, C2 and C3 that are updated and also affect B.
            // 64-bit hidden pointer is not a big deal, but it increases burden for the attacker significantly without adding much overhead to computing the hash function.
            // Remember that we try to be as fast as possible to cover as much memory as possible in a scarce amount of time.
            
            // Security analysis:
            // Lets say attacker wants to reduce amount of memory by a factor of 2.
            // He will complete 50% of needed computations with the available memory.
            // Then, to continue he will have to overwrite some bytes to continue hashing.
            // Attacker may figure out which bytes will be used in the very next step, so he may avoid overwriting them, but
            // he cannot know yet which ones will be used on the step after the next one.
            // So he will have a chance that one, two or three 64-bit blocks needed are overwritten.
            // That chance grows as more and more bytes are being overwritten.
            // We do not count cost of tracking overwritten blocks; assuming it's zero (although in practice it is not).
            // The cost of a missing 64-bit block is in the need to replay hashing from that position which involves two problems:
            //

            uint64_t a1 = *((uint64_t*)(spaceBytes + i - 32));
            uint64_t a2 = *((uint64_t*)(spaceBytes + i - 24));
            uint64_t a3 = *((uint64_t*)(spaceBytes + i - 16));
            uint64_t a4 = *((uint64_t*)(spaceBytes + i - 8));
            
            uint64_t* pc1 = (uint64_t*)(spaceBytes + (a1 % (i - 7)));
            uint64_t* pc2 = (uint64_t*)(spaceBytes + (((*pc1) ^ a2) % (i - 7)));
            uint64_t* pc3 = (uint64_t*)(spaceBytes + (((*pc2) ^ a3) % (i - 7)));
            
            CC_SHA512_Init(&ctx);
            CC_SHA512_Update(&ctx, pc1, 8);
            CC_SHA512_Update(&ctx, pc2, 8);
            CC_SHA512_Update(&ctx, pc3, 8);
            CC_SHA512_Update(&ctx, &a1, 8);
            CC_SHA512_Update(&ctx, &a2, 8);
            CC_SHA512_Update(&ctx, &a3, 8);
            CC_SHA512_Update(&ctx, &a4, 8);
            CC_SHA512_Update(&ctx, keyBytes, blockSize);
            CC_SHA512_Final(spaceBytes + i, &ctx); // put the results in the space so we don't need any extra memory for it. We'll take H1,H2,H3,H4 from spaceBytes[i + 32].

            // H1 -> C1
            *pc1 = *((uint64_t*)(spaceBytes + i + 32 + 0 ));
            
            // H2 -> C2
            *pc2 = *((uint64_t*)(spaceBytes + i + 32 + 8 ));
            
            // H3 -> C3
            *pc3 = *((uint64_t*)(spaceBytes + i + 32 + 16));
            
            // H4 -> A1
            *((uint64_t*)(spaceBytes + i - 32)) = *((uint64_t*)(spaceBytes + i + 32 + 24));
        }
        
        // The resulting key is simply the remaining bits of the data space.
        
        NSMutableData* result =  [NSMutableData dataWithBytes:spaceBytes + numberOfBytes - blockSize length:blockSize];
        
        BTCSecureMemset(&ctx,       0, sizeof(ctx));
        BTCSecureMemset(spaceBytes, 0, space.length);
        
        return result;
    }
}






