# SpeedPingTool
MARK: - 测速 + ping 工具

## 说明

```java
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

```

## 接口

### 初始化网络测速
```java
- (instancetype)initWithStepBlock:(speedStepBlock)stepBlock endBlock:(speedStepBlock)endBlock;

```

### 初始化ping
```java
- (instancetype)initAddress:(NSString *)IPAddress;

```
