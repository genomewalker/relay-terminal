// System-only network helper: no OpenConnect, shell, credentials or supplied paths.
#import "RelayVPNNetwork.h"
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>
#ifndef RELAY_VPN_AUTH_REQUIREMENT
#error Packaging must pin the exact authentication bridge code signature.
#endif
#define UTUN_CONTROL_NAME "com.apple.net.utun_control"
#define UTUN_OPT_IFNAME 2

static BOOL address(NSString *s, int family) {
    if (![s isKindOfClass:NSString.class] || !s.length || s.length > 64) return NO;
    unsigned char bytes[16]; return inet_pton(family, s.UTF8String, bytes) == 1;
}
static int family(NSString *s) { return address(s, AF_INET) ? AF_INET : address(s, AF_INET6) ? AF_INET6 : 0; }
static BOOL prefix(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return NO;
    NSArray *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count != 2 || !family(parts[0]) || ![parts[1] length]) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if ([parts[1] rangeOfCharacterFromSet:digits].location != NSNotFound) return NO;
    NSInteger n = [parts[1] integerValue]; return n >= 0 && n <= (family(parts[0]) == AF_INET ? 32 : 128);
}
static BOOL domain(NSString *s) {
    if (![s isKindOfClass:NSString.class] || !s.length || s.length > 253) return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"].invertedSet;
    return [s rangeOfCharacterFromSet:invalid].location == NSNotFound && ![s hasPrefix:@"-"];
}
static NSString *run(NSString *path, NSArray *arguments, BOOL *success) {
    NSTask *task = NSTask.new; NSPipe *pipe = NSPipe.pipe;
    task.executableURL = [NSURL fileURLWithPath:path]; task.arguments = arguments;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.environment = @{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin", @"LC_ALL":@"C"};
    // Only fixed system executables and bounded numeric/domain arguments are accepted.
    dispatch_semaphore_t ended = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) { dispatch_semaphore_signal(ended); };
    if (![task launchAndReturnError:nil]) { *success = NO; return @""; }
    if (dispatch_semaphore_wait(ended, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) {
        kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; *success = NO; return @"";
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    *success = task.terminationStatus == 0 && data.length <= 32768;
    return *success ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"" : @"";
}
static NSDictionary *routeTo(NSString *target, int af) {
    BOOL ok; NSString *out = run(@"/sbin/route", @[@"-n", @"get", af == AF_INET ? @"-inet" : @"-inet6", target], &ok);
    NSMutableDictionary *result = NSMutableDictionary.dictionary;
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *s = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSString *key in @[@"gateway", @"interface"])
            if ([s hasPrefix:[key stringByAppendingString:@":"]]) result[key] = [[s substringFromIndex:key.length+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return result;
}
static BOOL router(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return NO;
    NSArray *parts = [s componentsSeparatedByString:@"%"];
    if (parts.count == 1) return family(s) != 0;
    return parts.count == 2 && address(parts[0], AF_INET6) && if_nametoindex([parts[1] UTF8String]) != 0;
}
@class RelayVPNService;
@interface RelayVPNLease : NSObject <RelayVPNNetwork>
@property NSFileHandle *tun;
@property NSString *interface;
@property NSMutableArray<NSArray *> *routes;
@property NSMutableArray<NSString *> *dnsKeys;
@property SCDynamicStoreRef dns;
@property (weak) RelayVPNService *service;
- (void)cleanup;
@end
@interface RelayVPNService : NSObject <NSXPCListenerDelegate>
@property dispatch_queue_t queue;
@property (weak) RelayVPNLease *owner;
@end
@implementation RelayVPNLease
- (void)cleanup {
    if (self.dns) {
        for (NSString *key in self.dnsKeys) SCDynamicStoreRemoveValue(self.dns, (__bridge CFStringRef)key);
        CFRelease(self.dns); self.dns = NULL;
    }
    for (NSArray *args in self.routes.reverseObjectEnumerator) {
        // Added routes belong to this lease. Never remove an existing route we did not add.
        NSString *target = args[4]; int af = [args[2] isEqualToString:@"-inet"] ? AF_INET : AF_INET6;
        NSDictionary *now = routeTo(target, af);
        BOOL ours = [args[5] isEqualToString:@"-interface"] ? [now[@"interface"] isEqual:self.interface] : [now[@"gateway"] isEqual:args[6]];
        if (ours) { NSMutableArray *remove = args.mutableCopy; remove[1] = @"delete"; BOOL ok; run(@"/sbin/route", remove, &ok); }
    }
    [self.routes removeAllObjects];
    if (self.interface) { BOOL ok; run(@"/sbin/ifconfig", @[self.interface, @"down"], &ok); }
    [self.tun closeFile]; self.tun = nil; self.interface = nil;
    if (self.service.owner == self) self.service.owner = nil;
}
- (BOOL)addRoute:(NSString *)target interface:(BOOL)tunnel via:(NSString *)gateway host:(BOOL)host {
    int af = family([[target componentsSeparatedByString:@"/"] firstObject]);
    NSArray *args = @[@"-n", @"add", af == AF_INET ? @"-inet" : @"-inet6", host ? @"-host" : @"-net", target, tunnel ? @"-interface" : @"-gateway", tunnel ? self.interface : gateway];
    BOOL ok; run(@"/sbin/route", args, &ok);
    if (ok) [self.routes addObject:args];
    return ok;
}
- (void)configure:(NSDictionary *)settings reply:(void (^)(NSFileHandle *, NSString *, NSString *))reply {
    dispatch_async(self.service.queue, ^{
        if (self.service.owner) { reply(nil,nil,@"Another Relay VPN session owns the network helper."); return; }
        if (![settings isKindOfClass:NSDictionary.class] || settings.count > 12) { reply(nil,nil,@"Invalid network settings."); return; }
        NSString *ip = settings[@"address"], *mask = settings[@"netmask"], *ip6 = settings[@"address6"], *peer = settings[@"gateway"];
        NSArray *includes = settings[@"includes"], *excludes = settings[@"excludes"], *dns = settings[@"dns"], *domains = settings[@"domains"];
        NSNumber *mtu = settings[@"mtu"];
        BOOL valid = address(ip,AF_INET) && address(mask,AF_INET) && family(peer) && [mtu isKindOfClass:NSNumber.class] && mtu.intValue >= 576 && mtu.intValue <= 9000;
        valid &= !ip6 || [ip6 isEqual:@""] || prefix(ip6);
        for (NSArray *a in @[includes ?: @[], excludes ?: @[], dns ?: @[], domains ?: @[]]) valid &= [a isKindOfClass:NSArray.class] && a.count <= 128;
        if (!valid) { reply(nil,nil,@"Invalid network settings."); return; }
        for (NSString *p in includes) if (!prefix(p)) valid = NO;
        for (NSString *p in excludes) if (!prefix(p)) valid = NO;
        for (NSString *p in dns) if (!family(p)) valid = NO;
        for (NSString *p in domains) if (!domain(p)) valid = NO;
        if (!valid) { reply(nil,nil,@"Invalid routes or DNS settings."); return; }
        NSDictionary *physical4 = routeTo(@"default", AF_INET);
        NSDictionary *physical6 = routeTo(@"::/0", AF_INET6);
        NSDictionary *physical = routeTo(peer, family(peer));
        NSString *physicalGateway = physical[@"gateway"];
        if (!router(physicalGateway) || [physical[@"interface"] hasPrefix:@"utun"]) { reply(nil,nil,@"A physical network route is required. Disconnect other VPNs first."); return; }
        int fd = socket(PF_SYSTEM,SOCK_DGRAM,SYSPROTO_CONTROL);
        struct ctl_info info = {0}; strncpy(info.ctl_name,UTUN_CONTROL_NAME,sizeof(info.ctl_name)-1);
        struct sockaddr_ctl control = { .sc_len=sizeof(control), .sc_family=AF_SYSTEM, .ss_sysaddr=AF_SYS_CONTROL };
        if (fd < 0 || ioctl(fd,CTLIOCGINFO,&info) || (control.sc_id=info.ctl_id, connect(fd,(struct sockaddr *)&control,sizeof(control)))) {
            if (fd >= 0) close(fd); reply(nil,nil,@"Could not create a VPN interface."); return;
        }
        char name[IFNAMSIZ] = {0}; socklen_t length=sizeof(name);
        if (getsockopt(fd,SYSPROTO_CONTROL,UTUN_OPT_IFNAME,name,&length)) { close(fd); reply(nil,nil,@"Could not identify the VPN interface."); return; }
        self.interface = @(name); self.tun = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
        self.routes = NSMutableArray.array; self.dnsKeys = NSMutableArray.array; self.service.owner=self;
        BOOL ok;
        run(@"/sbin/ifconfig", @[self.interface,@"inet",ip,ip,@"netmask",mask,@"mtu",mtu.stringValue,@"up"], &ok);
        if (ok && ip6.length) run(@"/sbin/ifconfig",@[self.interface,@"inet6",ip6],&ok);
        if (ok) {
            // Only create a gateway pin when there is no existing host route.
            // Existing pins are left untouched; an added pin is removed at cleanup.
            BOOL added=[self addRoute:peer interface:NO via:physicalGateway host:YES];
            if (!added) { NSDictionary *existing=routeTo(peer,family(peer)); ok=[existing[@"gateway"] isEqual:physicalGateway] && ![existing[@"interface"] hasPrefix:@"utun"]; }
        }
        NSArray *wanted = includes.count ? includes : @[@"0.0.0.0/1",@"128.0.0.0/1",@"::/1",@"8000::/1"];
        for (NSString *p in wanted) if (ok) ok = [self addRoute:p interface:YES via:nil host:NO];
        for (NSString *p in excludes) if (ok) {
            int af=family([[p componentsSeparatedByString:@"/"] firstObject]);
            NSDictionary *base=af==AF_INET ? physical4 : physical6;
            NSString *gw=base[@"gateway"]; ok=router(gw) && ![base[@"interface"] hasPrefix:@"utun"];
            if (ok) ok=[self addRoute:p interface:NO via:gw host:NO];
        }
        if (ok && dns.count) {
            CFDictionaryRef options=(__bridge CFDictionaryRef)@{(__bridge NSString *)kSCDynamicStoreUseSessionKeys:@YES};
            self.dns=SCDynamicStoreCreateWithOptions(NULL,CFSTR("Relay VPN"),options,NULL,NULL);
            NSString *key=[NSString stringWithFormat:@"State:/Network/Service/dev.relay.vpn.%@/DNS",self.interface];
            NSArray *matches=domains.count ? domains : @[@""];
            NSMutableArray *orders=NSMutableArray.array; for(NSString *match in matches) [orders addObject:@100];
            NSDictionary *settings=@{@"ServerAddresses":dns,@"SupplementalMatchDomains":matches,@"SupplementalMatchOrders":orders,@"InterfaceName":self.interface};
            ok=self.dns && SCDynamicStoreSetValue(self.dns,(__bridge CFStringRef)key,(__bridge CFDictionaryRef)settings);
            if (ok) [self.dnsKeys addObject:key];
        }
        if (!ok) { [self cleanup]; reply(nil,nil,@"Network setup failed; changes were rolled back."); return; }
        reply(self.tun,self.interface,nil);
    });
}
- (void)disconnect:(void (^)(void))reply { dispatch_async(self.service.queue, ^{ [self cleanup]; reply(); }); }
@end
@implementation RelayVPNService
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    uid_t uid=0; gid_t gid=0; CFStringRef user=SCDynamicStoreCopyConsoleUser(NULL,&uid,&gid);
    if (user) CFRelease(user);
    if (!uid || connection.effectiveUserIdentifier != uid) return NO;
    RelayVPNLease *lease=RelayVPNLease.new; lease.service=self;
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(RelayVPNNetwork)];
    connection.exportedObject=lease;
    connection.invalidationHandler=^{ dispatch_async(self.queue, ^{ [lease cleanup]; }); };
    connection.interruptionHandler=^{ dispatch_async(self.queue, ^{ [lease cleanup]; }); };
    [connection resume]; return YES;
}
@end
int main(void) {
    @autoreleasepool {
        if (getuid()!=0) return 2;
        RelayVPNService *service=RelayVPNService.new;
        service.queue=dispatch_queue_create("relay.vpn.network",DISPATCH_QUEUE_SERIAL);
        NSXPCListener *listener=[[NSXPCListener alloc] initWithMachServiceName:RELAY_VPN_SERVICE];
        [listener setConnectionCodeSigningRequirement:@RELAY_VPN_AUTH_REQUIREMENT];
        listener.delegate=service; [listener resume]; [NSRunLoop.currentRunLoop run];
        return 0;
    }
}
