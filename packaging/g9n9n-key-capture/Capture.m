#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <util.h>
#include <termios.h>
#import "Protocol.h"

static volatile sig_atomic_t stopRequested=0;
static void onSignal(int s) { stopRequested=s; }
static CFStringRef domain=CFSTR("com.apple.MobileBluetooth.debug");
static NSString *statePath=@"/var/run/local.remote-key-bridge.state.plist";
static BOOL configure(id value) {
    CFPreferencesSetValue(CFSTR("HCITraces"),(__bridge CFPropertyListRef)value,domain,kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    return CFPreferencesSynchronize(domain,kCFPreferencesAnyUser,kCFPreferencesAnyHost);
}
static BOOL reloadBluetooth(void) {
    NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:@"/usr/bin/killall"];
    t.arguments=@[@"-USR1",@"bluetoothd"]; NSError *e=nil;
    if(![t launchAndReturnError:&e])return NO; [t waitUntilExit]; return t.terminationStatus==0;
}
static BOOL sendMessage(int fd,NSString *s) {
    NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b=d.bytes; NSUInteger offset=0;
    while(offset<d.length) { ssize_t n=send(fd,b+offset,d.length-offset,0); if(n<0&&errno==EINTR)continue; if(n<=0)return NO; offset+=n; }
    return YES;
}
static BOOL saveState(NSDictionary *state) {
    NSError *e=nil; NSData *d=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];
    if(!d || ![d writeToFile:statePath options:NSDataWritingAtomic error:&e])return NO;
    return chmod(statePath.fileSystemRepresentation,0600)==0;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(geteuid()!=0 || argc!=3)return 1;
    NSString *remoteAddress = [[NSString stringWithUTF8String:argv[2]] uppercaseString];
    if (!remoteAddress || [remoteAddress rangeOfString:@"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$"
                                               options:NSRegularExpressionSearch].location == NSNotFound) return 1;
    umask(0077); signal(SIGTERM,onSignal);signal(SIGINT,onSignal);signal(SIGHUP,onSignal);signal(SIGPIPE,SIG_IGN);
    // The root process only connects to a socket in a private directory owned by its peer.
    NSString *socketPath=[NSString stringWithUTF8String:argv[1]];
    struct stat ds,ss;
    if(lstat(socketPath.stringByDeletingLastPathComponent.fileSystemRepresentation,&ds)||!S_ISDIR(ds.st_mode)||(ds.st_mode&077)!=0||ds.st_uid==0||
       lstat(argv[1],&ss)||!S_ISSOCK(ss.st_mode)||ss.st_uid!=ds.st_uid||strlen(argv[1])>=sizeof(((struct sockaddr_un*)0)->sun_path))return 2;
    int client=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un addr={.sun_family=AF_UNIX};strlcpy(addr.sun_path,argv[1],sizeof(addr.sun_path));
    if(connect(client,(struct sockaddr*)&addr,sizeof(addr)))return 3;
    uid_t peerUID;gid_t peerGID;
    if(getpeereid(client,&peerUID,&peerGID)||peerUID!=ds.st_uid)return 4;
    struct timeval timeout={.tv_sec=2};setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    int lock=open("/var/run/local.remote-key-bridge.lock",O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)) {sendMessage(client,@"ERROR 另一个按键桥正在运行\n");return 5;}
    struct stat st;if(fstat(lock,&st)||st.st_uid!=0||!S_ISREG(st.st_mode))return 6;
    NSDictionary *old=[NSDictionary dictionaryWithContentsOfFile:statePath];
    if([old[@"active"] boolValue]) {
        if(!configure([old[@"originalPresent"] boolValue]?old[@"original"]:nil)||!reloadBluetooth()) {sendMessage(client,@"ERROR 无法恢复上次诊断设置\n");return 7;}
    }
    id original=CFBridgingRelease(CFPreferencesCopyValue(CFSTR("HCITraces"),domain,kCFPreferencesAnyUser,kCFPreferencesAnyHost));
    NSMutableDictionary *state=[@{@"active":@YES,@"originalPresent":@(original!=nil)} mutableCopy];if(original)state[@"original"]=original;
    if(!saveState(state)){sendMessage(client,@"ERROR 无法备份诊断设置\n");return 8;}
    NSTask *task=[NSTask new];int master=-1,slave=-1;int result=0;
    @try {
        if(!configure(@{@"StackDebugEnabled":@YES,@"HCILiveTraces":@YES,@"HCIFileTraces":@NO,@"RawAudioTrace":@NO,@"HIDTrace":@YES,@"HCISkipAuth":@NO})||!reloadBluetooth())
            @throw [NSException exceptionWithName:@"Setup" reason:@"无法开启实时按键通道" userInfo:nil];
        if(openpty(&master,&slave,NULL,NULL,NULL))@throw [NSException exceptionWithName:@"PTY" reason:@"无法建立实时通道" userInfo:nil];
        struct termios tty;tcgetattr(slave,&tty);cfmakeraw(&tty);tcsetattr(slave,TCSANOW,&tty);fcntl(master,F_SETFL,O_NONBLOCK);
        task.executableURL=[NSURL fileURLWithPath:@"/Applications/PacketLogger.app/Contents/Resources/packetlogger"];
        // timestamp, type, ADDRESS (never display name), handle, direction, raw bytes.
        task.arguments=@[@"convert",@"-s",@"-f",@"itpahdr"];
        NSFileHandle *out=[[NSFileHandle alloc] initWithFileDescriptor:slave closeOnDealloc:NO];
        task.standardOutput=out;task.standardError=out;task.standardInput=[NSFileHandle fileHandleWithNullDevice];
        NSError *e=nil;if(![task launchAndReturnError:&e])@throw [NSException exceptionWithName:@"Capture" reason:@"无法启动 PacketLogger" userInfo:nil];
        close(slave);slave=-1;
        NSMutableData *buffer=[NSMutableData data];BOOL ready=NO;
        sendMessage(client,@"STARTED\n");
        while(!stopRequested && task.running) { @autoreleasepool {
            struct pollfd fds[2]={{master,POLLIN,0},{client,POLLIN,0}};
            int r=poll(fds,2,250);if(r<0&&errno!=EINTR)break;
            if(fds[1].revents&(POLLIN|POLLHUP|POLLERR))break; // EOF or STOP from user process.
            if(fds[0].revents&(POLLHUP|POLLERR))break;
            if(fds[0].revents&POLLIN) {
                uint8_t bytes[16384];ssize_t n=read(master,bytes,sizeof(bytes));if(n<=0)continue;
                [buffer appendBytes:bytes length:n];
                for(;;) {
                    const uint8_t *start=buffer.bytes;const uint8_t *end=memchr(start,'\n',buffer.length);if(!end)break;
                    NSUInteger size=end-start;NSString *line=[[NSString alloc] initWithBytes:start length:size encoding:NSUTF8StringEncoding];
                    [buffer replaceBytesInRange:NSMakeRange(0,size+1) withBytes:NULL length:0];
                    if(!ready && [line containsString:@"\t"]){ready=YES;if(!sendMessage(client,@"READY\n"))stopRequested=1;}
                    NSString *event=line?RKDecodeLine(line, remoteAddress):nil;
                    if(event && !sendMessage(client,event))stopRequested=1;
                    if([line containsString:@"Bluetooth Profile Required"]){sendMessage(client,@"ERROR 系统未启用实时按键通道\n");stopRequested=1;}
                }
                if(buffer.length>65536)[buffer setLength:0];
            }
        }}
    } @catch(NSException *e) {sendMessage(client,[NSString stringWithFormat:@"ERROR %@\n",e.reason]);result=9;}
    @finally {
        sendMessage(client,@"RELEASE\n");
        if(task.running){[task terminate];for(int i=0;i<20&&task.running;i++)usleep(100000);if(task.running)kill(task.processIdentifier,SIGKILL);[task waitUntilExit];}
        if(master>=0)close(master);if(slave>=0)close(slave);
        BOOL restored=configure(original);BOOL reloaded=reloadBluetooth();
        state[@"active"]=@(!restored||!reloaded);state[@"restored"]=@(restored&&reloaded);saveState(state);
        sendMessage(client,restored&&reloaded?@"RESTORED\n":@"ERROR 诊断设置恢复失败，请重新开启后停止\n");
        if(!restored||!reloaded)result=10;
        close(client);close(lock);
    }
    return result;
}}
