//
//  SpeedPingTool.m
//  V606
//
//  Created by V606 on 2024/5/28.
//

#import "SpeedPingTool.h"
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#import "AppDelegate.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <arpa/inet.h>
#include <netdb.h>


static NSString * const SYSTEM_PUBLIC_RESOURCE_PATH = @"http://dl.360safe.com/wifispeed/wifispeed.test";
static CGFloat const SYSTEM_PUBLIC_REQUEST_COUNT = 10;


@implementation PingItemModel

- (instancetype)init {
    self = [super init];
    if (self) {
        self.host = @"";
        self.sendDate = [NSDate date];
        self.receiveDate = [NSDate date];
        self.rtt = 0;
    }
    return self;
}

- (NSTimeInterval)rtt {
    if (self.sendDate) {
        return [self.receiveDate timeIntervalSinceDate:self.sendDate] * 1000;
    } else {
        return 0;
    }
}

@end

@implementation SpeedItemModel

@end


@interface SystemTimer ()
@property (nonatomic, readwrite, copy) dispatch_block_t block;
@property (nonatomic, readwrite, strong) dispatch_source_t source;
@end

@implementation SystemTimer
@synthesize block = _block;
@synthesize source = _source;

+ (SystemTimer *)showTimeInterval:(NSTimeInterval)seconds block:(__strong dispatch_block_t)block {
    NSParameterAssert(seconds);
    NSParameterAssert(block);
    dispatch_queue_t queue = dispatch_queue_create("com.netease.timer", DISPATCH_QUEUE_SERIAL);
    SystemTimer *timer = [[self alloc] init];
    timer.block = block;
    timer.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    NSTimeInterval mSeconds = 1000 * seconds;
    uint64_t nsec = (uint64_t)(mSeconds * NSEC_PER_MSEC);
    dispatch_source_set_timer(timer.source, dispatch_walltime(NULL, 0), nsec, 0);
    dispatch_source_set_event_handler(timer.source, block);
    dispatch_resume(timer.source);
    return timer;
}

- (void)invalidate {
    if (self.source) {
        dispatch_source_cancel(self.source);
        self.source = nil;
    }
    self.block = nil;
}

- (void)dealloc {
    [self invalidate];
}

@end


static NSTimeInterval const kPendingPingsCleanupGrace = 1.0;


@interface V606PingTool ()
@property (assign, nonatomic) int socket;
@property (strong, nonatomic) NSData *hostAddress;
@property (strong, nonatomic) NSString *hostAddressString;
@property (assign, nonatomic) uint16_t identifier;
@property (assign, nonatomic) NSUInteger nextSequenceNumber;
@property (strong, nonatomic) NSMutableDictionary *pendingPings;
@property (strong, nonatomic) NSMutableDictionary *timeoutTimers;
@property (strong, nonatomic) dispatch_queue_t setupQueue;
@property (assign, nonatomic) BOOL isStopped;
@property (copy, nonatomic) pingBlock pingBlock;
@end

@implementation V606PingTool

- (instancetype)init {
    self = [super init];
    if (self) {
        self.host = @"";
        self.timeout = 2.0;
        self.ttl = 49;
    }
    return self;
}

- (void)setupPing:(pingStatusBlock)pingStatusBlock {
    __block NSError *error;
    if (self.isReady || self.host.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            pingStatusBlock(NO);
        });
    } else {
        self.nextSequenceNumber = 0;
        self.pendingPings = [[NSMutableDictionary alloc] init];
        self.timeoutTimers = [[NSMutableDictionary alloc] init];
        WeakSelf(weakSelf)
        dispatch_async(self.setupQueue, ^{
            CFStreamError streamError;
            BOOL success;
            CFHostRef hostRef = CFHostCreateWithName(NULL, (__bridge CFStringRef)weakSelf.host);
            if (hostRef) {
                success = CFHostStartInfoResolution(hostRef, kCFHostAddresses, &streamError);
            } else {
                success = NO;
            }
            if (!success) {
                NSDictionary *userInfo;
                if (streamError.domain == kCFStreamErrorDomainNetDB) {
                    userInfo = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInteger:streamError.error], kCFGetAddrInfoFailureKey, nil];
                } else {
                    userInfo = nil;
                }
                error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorUnknown userInfo:userInfo];
                [weakSelf stop];
                dispatch_async(dispatch_get_main_queue(), ^{
                    pingStatusBlock(NO);
                });
                if (hostRef) {
                    CFRelease(hostRef);
                }
            } else {
                Boolean resolved;
                const struct sockaddr *addrPtr = NULL;
                NSArray *addresses = (__bridge NSArray *)CFHostGetAddressing(hostRef, &resolved);
                if (resolved && (addresses != nil)) {
                    resolved = false;
                    for (NSData *address in addresses) {
                        const struct sockaddr *anAddrPtr = (const struct sockaddr *)[address bytes];
                        if ([address length] >= sizeof(struct sockaddr) && anAddrPtr->sa_family == AF_INET) {
                            resolved = true;
                            addrPtr = anAddrPtr;
                            weakSelf.hostAddress = address;
                            struct sockaddr_in *sin = (struct sockaddr_in *)anAddrPtr;
                            char str[INET_ADDRSTRLEN];
                            inet_ntop(AF_INET, &(sin->sin_addr), str, INET_ADDRSTRLEN);
                            weakSelf.hostAddressString = [[NSString alloc] initWithUTF8String:str];
                            break;
                        }
                    }
                }
                if (hostRef) {
                    CFRelease(hostRef);
                }
                if (!resolved) {
                    [weakSelf stop];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
                        pingStatusBlock(NO);
                    });
                } else {
                    int err = 0;
                    switch (addrPtr->sa_family) {
                        case AF_INET: {
                            weakSelf.socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
                            if (weakSelf.socket < 0) {
                                err = errno;
                            }
                        } break;
                        case AF_INET6: {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                pingStatusBlock(NO);
                            });
                            return;
                        } break;
                        default: {
                            err = EPROTONOSUPPORT;
                        } break;
                    }
                    if (err) {
                        [weakSelf stop];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
                            pingStatusBlock(NO);
                        });
                    } else {
                        if (weakSelf.ttl) {
                            u_char ttlForSockOpt = (u_char)weakSelf.ttl;
                            setsockopt(weakSelf.socket, IPPROTO_IP, IP_TTL, &ttlForSockOpt, sizeof(NSUInteger));
                        }
                        weakSelf.isReady = YES;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            pingStatusBlock(YES);
                        });
                    }
                }
            }
        });
        self.isStopped = NO;
    }
}

-(void)startPingBlock:(pingBlock)pingBlock {
    if (!self.isPinging) {
        NSThread *listenThread = [[NSThread alloc] initWithTarget:self selector:@selector(listenLoop) object:nil];
        listenThread.name = @"listenThread";
        NSThread *sendThread = [[NSThread alloc] initWithTarget:self selector:@selector(sendLoop) object:nil];
        sendThread.name = @"sendThread";
        self.isPinging = YES;
        [listenThread start];
        [sendThread start];
    }
}

- (void)listenLoop {
    WeakSelf(weakSelf)
    @autoreleasepool {
        while (weakSelf.isPinging) {
            [weakSelf listenOnce];
        }
    }
}

- (void)listenOnce {
    int                     err;
    struct sockaddr_storage addr;
    socklen_t               addrLen;
    ssize_t                 bytesRead;
    void *                  buffer;
    enum { kBufferSize = 65535 };
    buffer = malloc(kBufferSize);
    assert(buffer);
    
    //read the data.
    addrLen = sizeof(addr);
    bytesRead = recvfrom(self.socket, buffer, kBufferSize, 0, (struct sockaddr *)&addr, &addrLen);
    err = 0;
    if (bytesRead < 0) {
        err = errno;
    }
    
    //process the data we read.
    if (bytesRead > 0) {
        char hoststr[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *)&addr;
        inet_ntop(AF_INET, &(sin->sin_addr), hoststr, INET_ADDRSTRLEN);
        NSString *host = [[NSString alloc] initWithUTF8String:hoststr];
        
        if([host isEqualToString:self.hostAddressString]) { // only make sense where received packet comes from expected source
            NSDate *receiveDate = [NSDate date];
            NSMutableData *packet;
            
            packet = [NSMutableData dataWithBytes:buffer length:(NSUInteger) bytesRead];
            assert(packet);
            
            //complete the ping summary
            const struct ICMPHeader *headerPointer = [[self class] icmpInPacket:packet];
            NSUInteger seqNo = (NSUInteger)OSSwapBigToHostInt16(headerPointer->sequenceNumber);
            NSNumber *key = @(seqNo);
            PingItemModel *pingSummary = [(PingItemModel *)self.pendingPings[key] copy];
            if (pingSummary) {
                if ([self isValidPingResponsePacket:packet]) {
                    //override the source address (we might have sent to google.com and 172.123.213.192 replied)
                    pingSummary.receiveDate = receiveDate;
                    pingSummary.host = [[self class] sourceAddressInPacket:packet];
                    
                    
                    //invalidate the timeouttimer
                    NSTimer *timer = self.timeoutTimers[key];
                    [timer invalidate];
                    [self.timeoutTimers removeObjectForKey:key];
                    WeakSelf(weakSelf)
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (weakSelf.pingBlock) {
                            weakSelf.pingBlock(pingSummary);
                        }
                    });
                } else {
                    WeakSelf(weakSelf)
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (weakSelf.pingBlock) {
                            weakSelf.pingBlock(pingSummary);
                        }
                    });
                }
            }
        }
    } else {
        if (err == 0) {
            err = EPIPE;
        }
        if (!self.isStopped) {
            WeakSelf(weakSelf)
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.pingBlock) {
                    weakSelf.pingBlock([[PingItemModel alloc] init]);
                }
            });
        }
        //stop the whole thing
        [self stop];
    }
    free(buffer);
}

- (void)sendLoop {
    @autoreleasepool {
        while (self.isPinging) {
            [self sendPing];
            NSTimeInterval runUntil = CFAbsoluteTimeGetCurrent() + 1.0;
            NSTimeInterval time = 0;
            while (runUntil > time) {
                NSDate *runUntilDate = [NSDate dateWithTimeIntervalSinceReferenceDate:runUntil];
                [[NSRunLoop currentRunLoop] runUntilDate:runUntilDate];
                time = CFAbsoluteTimeGetCurrent();
            }
        }
    }
}

- (void)sendPing {
    if (self.isPinging) {
        int err;
        NSMutableData *packet;
        ICMPHeader *icmpPtr;
        ssize_t bytesSent;
        
        // Construct the ping packet.
        NSData *payload = [self generateDataWithLength:(56)];
        
        packet = [NSMutableData dataWithLength:sizeof(*icmpPtr) + [payload length]];
        
        icmpPtr = [packet mutableBytes];
        icmpPtr->type = kICMPTypeEchoRequest;
        icmpPtr->code = 0;
        icmpPtr->checksum = 0;
        icmpPtr->identifier     = OSSwapHostToBigInt16(self.identifier);
        icmpPtr->sequenceNumber = OSSwapHostToBigInt16(self.nextSequenceNumber);
        memcpy(&icmpPtr[1], [payload bytes], [payload length]);
        
        // The IP checksum returns a 16-bit number that's already in correct byte order
        // (due to wacky 1's complement maths), so we just put it into the packet as a
        // 16-bit unit.
        icmpPtr->checksum = in_cksum([packet bytes], [packet length]);
        
        // this is our ping summary
        PingItemModel *newPingSummary = [[PingItemModel alloc] init];
        
        // Send the packet.
        if (self.socket == 0) {
            bytesSent = -1;
            err = EBADF;
        }
        else {
            
            //record the send date
            NSDate *sendDate = [NSDate date];
            
            //construct ping summary, as much as it can
            newPingSummary.host = self.host;
            newPingSummary.sendDate = sendDate;
            
            //add it to pending pings
            NSNumber *key = @(self.nextSequenceNumber);
            self.pendingPings[key] = newPingSummary;
            
            //increment sequence number
            self.nextSequenceNumber += 1;
            
            //we create a copy, this one will be passed out to other threads
//            SuperPingSummary *pingSummaryCopy = [newPingSummary copy];
            
            //we need to clean up our list of pending pings, and we do that after the timeout has elapsed (+ some grace period)
            WeakSelf(weakSelf)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((self.timeout + kPendingPingsCleanupGrace) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                //remove the ping from the pending list
                [weakSelf.pendingPings removeObjectForKey:key];
            });
            
            //add a timeout timer
            //add a timeout timer
            NSTimer *timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:self.timeout
                                                                     target:[NSBlockOperation blockOperationWithBlock:^{
                                
                //notify about the failure
                WeakSelf(weakSelf)
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (weakSelf.pingBlock) {
                        weakSelf.pingBlock(newPingSummary);
                    }
                });
                
                [weakSelf.timeoutTimers removeObjectForKey:key];
            }]
                                                                   selector:@selector(main)
                                                                   userInfo:nil
                                                                    repeats:NO];
            [[NSRunLoop mainRunLoop] addTimer:timeoutTimer forMode:NSRunLoopCommonModes];
            
            //keep a local ref to it
            if (self.timeoutTimers) {
                self.timeoutTimers[key] = timeoutTimer;
            }
            
            //notify delegate about this
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.pingBlock) {
                    weakSelf.pingBlock(newPingSummary);
                }
            });
            
            bytesSent = sendto(
                               self.socket,
                               [packet bytes],
                               [packet length],
                               0,
                               (struct sockaddr *) [self.hostAddress bytes],
                               (socklen_t) [self.hostAddress length]
                               );
            err = 0;
            if (bytesSent < 0) {
                err = errno;
            }
        }
        
        // This is after the sending
        
        //successfully sent
        if ((bytesSent > 0) && (((NSUInteger) bytesSent) == [packet length])) {
            //noop, we already notified delegate about sending of the ping
        }
        //failed to send
        else {
            //complete the error
            if (err == 0) {
                err = ENOBUFS;          // This is not a hugely descriptor error, alas.
            }
            WeakSelf(weakSelf)
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.pingBlock) {
                    weakSelf.pingBlock(newPingSummary);
                }
            });
        }
    }
}

- (void)stop {
    WeakSelf(weakSelf)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf.isStopped) {
            weakSelf.isPinging = NO;
            
            weakSelf.isReady = NO;
            
            //destroy listenThread by closing socket (listenThread)
            if (weakSelf.socket) {
                close(weakSelf.socket);
                weakSelf.socket = 0;
            }
            
            //destroy host
            weakSelf.hostAddress = nil;
            
            //clean up pendingpings
            [weakSelf.pendingPings removeAllObjects];
            weakSelf.pendingPings = nil;
            for (NSNumber *key in [weakSelf.timeoutTimers copy]) {
                NSTimer *timer = weakSelf.timeoutTimers[key];
                [timer invalidate];
            }
            
            //clean up timeouttimers
            [weakSelf.timeoutTimers removeAllObjects];
            weakSelf.timeoutTimers = nil;
            
            //reset seq number
            weakSelf.nextSequenceNumber = 0;
            
            weakSelf.isStopped = YES;
        }
    });
}

#pragma mark - util

static uint16_t in_cksum(const void *buffer, size_t bufferLen) {
    size_t              bytesLeft;
    int32_t             sum;
    const uint16_t *    cursor;
    union {
        uint16_t        us;
        uint8_t         uc[2];
    } last;
    uint16_t            answer;
    
    bytesLeft = bufferLen;
    sum = 0;
    cursor = buffer;
    
    /*
     * Our algorithm is simple, using a 32 bit accumulator (sum), we add
     * sequential 16 bit words to it, and at the end, fold back all the
     * carry bits from the top 16 bits into the lower 16 bits.
     */
    while (bytesLeft > 1) {
        sum += *cursor;
        cursor += 1;
        bytesLeft -= 2;
    }
    
    /* mop up an odd byte, if necessary */
    if (bytesLeft == 1) {
        last.uc[0] = * (const uint8_t *) cursor;
        last.uc[1] = 0;
        sum += last.us;
    }
    
    /* add back carry outs from top 16 bits to low 16 bits */
    sum = (sum >> 16) + (sum & 0xffff);    /* add hi 16 to low 16 */
    sum += (sum >> 16);            /* add carry */
    answer = (uint16_t) ~sum;   /* truncate to 16 bits */
    
    return answer;
}

+ (NSString *)sourceAddressInPacket:(NSData *)packet {
    const struct IPHeader   *ipPtr;
    const uint8_t           *sourceAddress;
    
    if ([packet length] >= sizeof(IPHeader)) {
        ipPtr = (const IPHeader *)[packet bytes];
        
        sourceAddress = ipPtr->sourceAddress;//dont need to swap byte order those cuz theyre the smallest atomic unit (1 byte)
        NSString *ipString = [NSString stringWithFormat:@"%d.%d.%d.%d", sourceAddress[0], sourceAddress[1], sourceAddress[2], sourceAddress[3]];
        
        return ipString;
    }
    else return nil;
}

+ (NSUInteger)icmpHeaderOffsetInPacket:(NSData *)packet {
    NSUInteger              result;
    const struct IPHeader * ipPtr;
    size_t                  ipHeaderLength;
    
    result = NSNotFound;
    if ([packet length] >= (sizeof(IPHeader) + sizeof(ICMPHeader))) {
        ipPtr = (const IPHeader *) [packet bytes];
        assert((ipPtr->versionAndHeaderLength & 0xF0) == 0x40);     // IPv4
        assert(ipPtr->protocol == 1);                               // ICMP
        ipHeaderLength = (ipPtr->versionAndHeaderLength & 0x0F) * sizeof(uint32_t);
        if ([packet length] >= (ipHeaderLength + sizeof(ICMPHeader))) {
            result = ipHeaderLength;
        }
    }
    return result;
}

+ (const struct ICMPHeader *)icmpInPacket:(NSData *)packet {
    const struct ICMPHeader *   result;
    NSUInteger                  icmpHeaderOffset;
    
    result = nil;
    icmpHeaderOffset = [self icmpHeaderOffsetInPacket:packet];
    if (icmpHeaderOffset != NSNotFound) {
        result = (const struct ICMPHeader *) (((const uint8_t *)[packet bytes]) + icmpHeaderOffset);
    }
    return result;
}

- (BOOL)isValidPingResponsePacket:(NSMutableData *)packet {
    BOOL                result;
    NSUInteger          icmpHeaderOffset;
    ICMPHeader *        icmpPtr;
    uint16_t            receivedChecksum;
    uint16_t            calculatedChecksum;
    
    result = NO;
    
    icmpHeaderOffset = [[self class] icmpHeaderOffsetInPacket:packet];
    if (icmpHeaderOffset != NSNotFound) {
        icmpPtr = (struct ICMPHeader *) (((uint8_t *)[packet mutableBytes]) + icmpHeaderOffset);
        
        receivedChecksum   = icmpPtr->checksum;
        icmpPtr->checksum  = 0;
        calculatedChecksum = in_cksum(icmpPtr, [packet length] - icmpHeaderOffset);
        icmpPtr->checksum  = receivedChecksum;
        
        if (receivedChecksum == calculatedChecksum) {
            if ( (icmpPtr->type == kICMPTypeEchoReply) && (icmpPtr->code == 0) ) {
                if ( OSSwapBigToHostInt16(icmpPtr->identifier) == self.identifier ) {
                    if ( OSSwapBigToHostInt16(icmpPtr->sequenceNumber) < self.nextSequenceNumber ) {
                        result = YES;
                    }
                }
            }
        }
    }
    return result;
}

- (NSData *)generateDataWithLength:(NSUInteger)length {
    char tempBuffer[length];
    memset(tempBuffer, 7, length);
    
    return [[NSData alloc] initWithBytes:tempBuffer length:length];
}

- (void)_invokeTimeoutCallback:(NSTimer *)timer {
    dispatch_block_t callback = timer.userInfo;
    if (callback) {
        callback();
    }
}


@end


@interface SpeedPingTool ()
@property (copy, nonatomic) speedStepBlock stepBlock;
@property (copy, nonatomic) speedStepBlock endBlock;
@property (copy, nonatomic) pingBlock pingBlock;
@property (assign, nonatomic) NSInteger SpeedAllSecond; // 网络总计时
@property (strong, nonatomic) NSMutableData *SpeedStepData; // 最小数据量
@property (strong, nonatomic) NSMutableData *SpeedEndData; // 总数据量
@property (strong, nonatomic) NSURLSessionDataTask *SpeedRequestTask;
@property (strong, nonatomic) SystemTimer *speedTimer;
// ping
@property (strong, nonatomic) V606PingTool *pingService;

@end


@implementation SpeedPingTool

- (instancetype)initWithStepBlock:(speedStepBlock)stepBlock endBlock:(speedStepBlock)endBlock {
    self = [super init];
    if (self) {
        self.stepBlock = stepBlock;
        self.endBlock = endBlock;
        self.SpeedStepData = [[NSMutableData alloc] init];
        self.SpeedEndData = [[NSMutableData alloc] init];
    }
    return self;
}

- (instancetype)initAddress:(NSString *)IPAddress {
    self = [super init];
    if (self) {
        self.pingService.host = IPAddress;
    }
    return self;
}

# pragma - Ping

- (void)startPing:(pingBlock)pingBlock {
    self.pingBlock = pingBlock;
    WeakSelf(weakSelf)
    [self.pingService setupPing:^(BOOL pingStatus) {
        if (pingStatus) {
            [weakSelf.pingService startPingBlock:^(PingItemModel * _Nonnull pingItem) {
                [weakSelf.pingService stop];
                if (weakSelf.pingBlock) {
                    weakSelf.pingBlock(pingItem);
                }
            }];
        } else {
            weakSelf.pingBlock([[PingItemModel alloc] init]);
        }
    }];
}


# pragma - 系统网卡测试

// 设备端口测速
- (void)startSystemPortStepSpeed {
    self.SpeedAllSecond = 0;
    WeakSelf(weakSelf)
    self.speedTimer = [SystemTimer showTimeInterval:0.1 block:^{
        ++weakSelf.SpeedAllSecond;
        if (weakSelf.SpeedAllSecond >= SYSTEM_PUBLIC_REQUEST_COUNT) {
            if (weakSelf.endBlock) {
                weakSelf.endBlock([weakSelf speedModelForNumber:[[weakSelf interfaceBytes][1] floatValue] upload:[[weakSelf interfaceBytes][0] floatValue]]);
            }
            return;
        }
        // 每0.1秒即时数据,block 回传
        if (weakSelf.stepBlock) {
            weakSelf.stepBlock([weakSelf speedModelForNumber:[[weakSelf interfaceBytes][1] floatValue] upload:[[weakSelf interfaceBytes][0] floatValue]]);
        }
        // 清空即时数据
        [weakSelf.SpeedStepData resetBytesInRange: NSMakeRange(0, weakSelf.SpeedStepData.length)];
        [weakSelf.SpeedStepData setLength:0];
    }];
}

- (NSArray <NSString *> *)interfaceBytes {
    NSMutableArray *dataMutabArray = [NSMutableArray array];
    struct ifaddrs *ifa_list = 0, *ifa;
    if (getifaddrs(&ifa_list) == -1) {
        return 0;
    }
    uint32_t download = 0;
    uint32_t upload = 0;
    for (ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
        if (AF_LINK != ifa->ifa_addr->sa_family)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING))
            continue;
        if (ifa->ifa_data == 0)
            continue;
        if (strncmp(ifa->ifa_name, "lo", 2)) {
            struct if_data *if_data = (struct if_data *)ifa->ifa_data;
            //下行
            download += if_data->ifi_ibytes;
            //上行
            upload += if_data->ifi_obytes;
        }
    }
    freeifaddrs(ifa_list);
    [dataMutabArray addObject:[NSString stringWithFormat:@"%u", upload]];
    [dataMutabArray addObject:[NSString stringWithFormat:@"%u", download]];
    return dataMutabArray;
}


# pragma - 网络下载数据测试

// 网络下载测速
- (void)startNetStepSpeed {
    self.SpeedRequestTask = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL: [NSURL URLWithString: SYSTEM_PUBLIC_RESOURCE_PATH]]];
    [self.SpeedRequestTask resume];
    self.SpeedAllSecond = 0;
    WeakSelf(weakSelf)
    self.speedTimer = [SystemTimer showTimeInterval:0.1 block:^{
        ++weakSelf.SpeedAllSecond;
        if (weakSelf.SpeedAllSecond >= SYSTEM_PUBLIC_REQUEST_COUNT) {
            [weakSelf endNetSpeed];
            return;
        }
        // 每0.1秒即时数据,block 回传
        if (weakSelf.stepBlock) {
            weakSelf.stepBlock([weakSelf speedModelForNumber:weakSelf.SpeedStepData.length upload:weakSelf.SpeedStepData.length]);
        }
        // 清空即时数据
        [weakSelf.SpeedStepData resetBytesInRange: NSMakeRange(0, weakSelf.SpeedStepData.length)];
        [weakSelf.SpeedStepData setLength:0];
    }];
}

- (void)endNetSpeed {
    // 取消定时器
    [self.speedTimer invalidate];
    self.speedTimer = nil;
    if (self.SpeedAllSecond != 0) {
        if (self.stepBlock) {
            self.stepBlock([self speedModelForNumber:self.SpeedEndData.length / self.SpeedAllSecond upload:self.SpeedEndData.length / self.SpeedAllSecond]);
        }
    }
    [self.SpeedRequestTask cancel];
    self.SpeedRequestTask = nil;
    self.SpeedEndData = [[NSMutableData alloc] init];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.SpeedStepData appendData: data];
    [self.SpeedEndData appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error == nil) {
        [self endNetSpeed];
    }
}

# pragma - 公共接口方法

- (SpeedItemModel *)speedModelForNumber:(CGFloat)download upload:(CGFloat)upload {
    SpeedItemModel *speedModel = [[SpeedItemModel alloc] init];
    NSArray<NSString *> *uploadArray = [self speedStringWithNumber:upload];
    NSArray<NSString *> *downloadArray = [self speedStringWithNumber:download];
    speedModel.uploadString = uploadArray[0];
    speedModel.uploadUnit = uploadArray[1];
    speedModel.downloadString = downloadArray[0];
    speedModel.downloadUnit = downloadArray[1];
    return speedModel;
}

- (NSArray <NSString *> *)speedStringWithNumber:(CGFloat)number {
    NSMutableArray<NSString *> *dataMutabArray = [NSMutableArray array];
    if (number < 1024) {
        [dataMutabArray addObject:[NSString stringWithFormat:@"%0.2f", (double)number / 1024]];
        [dataMutabArray addObject:@"DB/s"];
    } else if (number >= 1024 && number < (1024 * 1024)) {
        [dataMutabArray addObject:[NSString stringWithFormat:@"%0.2f", (double)number / (1024 * 1024) + ((arc4random() % 100) * 0.01)]];
        [dataMutabArray addObject:@"KB/s"];
    } else if (number >= (1024 * 1024) && number < (1024 * 1024 * 1024)) {
        [dataMutabArray addObject:[NSString stringWithFormat:@"%0.2f", (double)number / (1024 * 1024 * 1024) + ((arc4random() % 100) * 0.01)]];
        [dataMutabArray addObject:@"MB/s"];
    } else {
        [dataMutabArray addObject:[NSString stringWithFormat:@"%0.2f", ((double)number / (1024 * 1024 * 1024) + ((arc4random() % 100) * 0.01))]];
        [dataMutabArray addObject:@"MB/s"];
    }
    return [dataMutabArray copy];
}


- (V606PingTool *)pingService {
    if (!_pingService) {
        _pingService = [[V606PingTool alloc] init];
    }
    return _pingService;
}

@end


