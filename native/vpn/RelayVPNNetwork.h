#import <Foundation/Foundation.h>
#define RELAY_VPN_SERVICE @"dev.relay.terminal.vpn-network"
@protocol RelayVPNNetwork
- (void)configure:(NSDictionary *)settings reply:(void (^)(NSFileHandle *, NSString *, NSString *))reply;
- (void)disconnect:(void (^)(void))reply;
@end
