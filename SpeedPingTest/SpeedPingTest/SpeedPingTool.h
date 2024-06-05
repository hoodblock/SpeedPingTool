//
//  SpeedPingTool.h
//  V606
//
//  Created by V606 on 2024/5/28.
//

#import <Foundation/Foundation.h>
#include <AssertMacros.h>
#if TARGET_OS_EMBEDDED || TARGET_IPHONE_SIMULATOR
#import <CFNetwork/CFNetwork.h>
#else
#import <CoreServices/CoreServices.h>
#endif


#define WeakSelf(weakSelf)  __weak __typeof(&*self)weakSelf = self;


NS_ASSUME_NONNULL_BEGIN

struct IPHeader {
    uint8_t     versionAndHeaderLength;
    uint8_t     differentiatedServices;
    uint16_t    totalLength;
    uint16_t    identification;
    uint16_t    flagsAndFragmentOffset;
    uint8_t     timeToLive;
    uint8_t     protocol;
    uint16_t    headerChecksum;
    uint8_t     sourceAddress[4];
    uint8_t     destinationAddress[4];
    // options...
    // data...
};
typedef struct IPHeader IPHeader;

__Check_Compile_Time((sizeof(IPHeader)) == 20);
__Check_Compile_Time(offsetof(IPHeader, versionAndHeaderLength) == 0);
__Check_Compile_Time(offsetof(IPHeader, differentiatedServices) == 1);
__Check_Compile_Time(offsetof(IPHeader, totalLength) == 2);
__Check_Compile_Time(offsetof(IPHeader, identification) == 4);
__Check_Compile_Time(offsetof(IPHeader, flagsAndFragmentOffset) == 6);
__Check_Compile_Time(offsetof(IPHeader, timeToLive) == 8);
__Check_Compile_Time(offsetof(IPHeader, protocol) == 9);
__Check_Compile_Time(offsetof(IPHeader, headerChecksum) == 10);
__Check_Compile_Time(offsetof(IPHeader, sourceAddress) == 12);
__Check_Compile_Time(offsetof(IPHeader, destinationAddress) == 16);

// ICMP type and code combinations:

enum {
    kICMPTypeEchoReply   = 0,           // code is always 0
    kICMPTypeEchoRequest = 8            // code is always 0
};

// ICMP header structure:

struct ICMPHeader {
    uint8_t     type;
    uint8_t     code;
    uint16_t    checksum;
    uint16_t    identifier;
    uint16_t    sequenceNumber;
    // data...
};
typedef struct ICMPHeader ICMPHeader;

__Check_Compile_Time(sizeof(ICMPHeader) == 8);
__Check_Compile_Time(offsetof(ICMPHeader, type) == 0);
__Check_Compile_Time(offsetof(ICMPHeader, code) == 1);
__Check_Compile_Time(offsetof(ICMPHeader, checksum) == 2);
__Check_Compile_Time(offsetof(ICMPHeader, identifier) == 4);
__Check_Compile_Time(offsetof(ICMPHeader, sequenceNumber) == 6);


@interface PingItemModel : NSObject
@property (strong, nonatomic) NSString          *host;
@property (strong, nonatomic) NSDate            *sendDate;
@property (strong, nonatomic) NSDate            *receiveDate;
@property (assign, nonatomic) NSTimeInterval    rtt;
@end

@interface SpeedItemModel : NSObject
@property (strong, nonatomic) NSString *downloadString;
@property (strong, nonatomic) NSString *downloadUnit;
@property (strong, nonatomic) NSString *uploadString;
@property (strong, nonatomic) NSString *uploadUnit;
@end

typedef void(^speedStepBlock)(SpeedItemModel *itemModel);
typedef void(^pingBlock)(PingItemModel *pingItem);
typedef void(^pingStatusBlock)(BOOL pingStatus);

/*
 *
 * 1: 用网络请求可以取公共资源库上传和下载数据，然后根据时间计算网速
 ******* 下载公共资源包：- http://dl.360safe.com/wifispeed/wifispeed.test // 3M的资源包
 ******* 下载速度为真，上传速度为假，辅助
 *
 *
 * 2: 随机取值法 + 网端取值法
 ******* 使用设备网络端口取前一秒和下一秒的网络流量
 ******* 不太正确
 *
*/


@interface SystemTimer : NSObject
+ (SystemTimer *)showTimeInterval:(NSTimeInterval)seconds block:(dispatch_block_t)block;
- (void)invalidate;
@end


@interface V606PingTool : NSObject

@property (strong, nonatomic) NSString *host;
@property (assign, nonatomic) NSUInteger payloadSize;
@property (assign, nonatomic) NSUInteger ttl;
@property (assign, nonatomic) NSTimeInterval timeout;
@property (assign, nonatomic) NSTimeInterval pingPeriod;
@property (assign, nonatomic) BOOL isPinging;
@property (assign, nonatomic) BOOL isReady;

- (void)setupPing:(pingStatusBlock)pingStatusBlock;

- (void)startPingBlock:(pingBlock)pingBlock;

@end



@interface SpeedPingTool : NSObject

// 初始化网络测速工具
- (instancetype)initWithStepBlock:(speedStepBlock)stepBlock endBlock:(speedStepBlock)endBlock;

// 初始化ping工具
- (instancetype)initAddress:(NSString *)IPAddress;

// 网络下载测速
- (void)startNetStepSpeed;

// 设备端口测速
- (void)startSystemPortStepSpeed;

// ping 回调
- (void)startPing:(pingBlock)pingBlock;


@end

NS_ASSUME_NONNULL_END
