// Unprivileged authentication bridge. No tunnel, credential store or raw logging.
#import <Foundation/Foundation.h>
#include <openconnect.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#import <Security/Security.h>
#import "RelayVPNNetwork.h"
#include <arpa/inet.h>

static int sequence;
static volatile sig_atomic_t commandFD = -1;
static void cancelSignal(int signal) { if (commandFD >= 0) { char command = OC_CMD_CANCEL; (void)write(commandFD, &command, 1); } }
static NSString *text(const char *s) {
    if (!s) return @"";
    NSString *value = [[NSString alloc] initWithBytes:s length:strnlen(s, 8192) encoding:NSUTF8StringEncoding] ?: @"";
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}
static void emit(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data || data.length > 65536) return;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static NSString *signedRequirement(NSURL *url) {
    SecStaticCodeRef code = NULL; CFDictionaryRef information = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    OSStatus valid = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures | kSecCSStrictValidate, NULL);
    if (valid == errSecSuccess) valid = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    CFRelease(code);
    if (valid != errSecSuccess || !information) return nil;
    NSDictionary *info = CFBridgingRelease(information);
    NSData *hash = info[(__bridge NSString *)kSecCodeInfoUnique];
    if (![hash isKindOfClass:NSData.class] || hash.length != 20) return nil;
    NSMutableString *hex=NSMutableString.string;
    for (NSUInteger i=0;i<hash.length;i++) [hex appendFormat:@"%02x",((const unsigned char *)hash.bytes)[i]];
    return [NSString stringWithFormat:@"cdhash H\"%@\"",hex];
}
static NSString *normalizedPrefix(const char *source) {
    NSString *s = source ? @(source) : @"";
    NSArray *parts=[s componentsSeparatedByString:@"/"];
    if (parts.count == 1) return [s stringByAppendingString:[s containsString:@":"] ? @"/128" : @"/32"];
    if (parts.count != 2) return @"";
    if ([parts[1] containsString:@"."]) {
        struct in_addr mask;
        if (inet_pton(AF_INET,[parts[1] UTF8String],&mask)!=1) return @"";
        uint32_t bits=ntohl(mask.s_addr); int prefix=0; BOOL ended=NO;
        for(int i=31;i>=0;i--) { if(bits & (1u<<i)) { if(ended) return @""; prefix++; } else ended=YES; }
        return [NSString stringWithFormat:@"%@/%d",parts[0],prefix];
    }
    return s;
}
static NSArray *routes(struct oc_split_include *next) {
    NSMutableArray *result=NSMutableArray.array;
    while(next) { [result addObject:normalizedPrefix(next->route)]; next=next->next; if(result.count>128) break; }
    return result;
}
static int tunnel(struct openconnect_info *vpn) {
    emit(@{@"type":@"progress",@"message":@"Establishing the VPN tunnel…"});
    if (openconnect_make_cstp_connection(vpn)) return -1;
    const struct oc_ip_info *info=NULL;
    if(openconnect_get_ip_info(vpn,&info,NULL,NULL) || !info) return -1;
    NSMutableArray *dns=NSMutableArray.array,*domains=NSMutableArray.array;
    for(int i=0;i<3;i++) if(info->dns[i]) [dns addObject:@(info->dns[i])];
    for(struct oc_split_include *d=info->split_dns;d;d=d->next) { [domains addObject:text(d->route)]; if(domains.count>128) return -1; }
    NSDictionary *settings=@{@"address":text(info->addr),@"netmask":text(info->netmask),@"address6":text(info->netmask6 ?: info->addr6),@"gateway":text(info->gateway_addr),@"mtu":@(info->mtu),@"includes":routes(info->split_includes),@"excludes":routes(info->split_excludes),@"dns":dns,@"domains":domains};
    NSString *binary=NSProcessInfo.processInfo.arguments[0];
    NSURL *helper=[NSURL fileURLWithPath:[[binary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"relay-vpn-network"]];
    NSString *requirement=signedRequirement(helper);
    if(!requirement) { emit(@{@"type":@"error",@"message":@"The VPN network helper signature is invalid."}); return -1; }
    NSXPCConnection *connection=[[NSXPCConnection alloc] initWithMachServiceName:RELAY_VPN_SERVICE options:NSXPCConnectionPrivileged];
    [connection setCodeSigningRequirement:requirement];
    connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(RelayVPNNetwork)];
    connection.invalidationHandler=^{ cancelSignal(SIGTERM); };
    connection.interruptionHandler=^{ cancelSignal(SIGTERM); };
    [connection resume];
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    __block NSFileHandle *tun=nil; __block NSString *interface=nil; __block NSString *failure=nil;
    id<RelayVPNNetwork> network=[connection remoteObjectProxyWithErrorHandler:^(NSError *error) { failure=@"Approve the Relay VPN network helper in System Settings first."; dispatch_semaphore_signal(ready); }];
    [network configure:settings reply:^(NSFileHandle *handle,NSString *name,NSString *error) { tun=handle; interface=name; failure=error; dispatch_semaphore_signal(ready); }];
    if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)) || !tun || failure) {
        emit(@{@"type":@"error",@"message":failure ?: @"VPN network setup timed out."}); [connection invalidate]; return -1;
    }
    int fd=dup(tun.fileDescriptor); [tun closeFile]; tun=nil;
    if(fd<0 || openconnect_setup_tun_fd(vpn,fd)) { [connection invalidate]; return -1; }
    (void)openconnect_setup_dtls(vpn,30);
    emit(@{@"type":@"connected",@"message":@"VPN connected.",@"interface":interface ?: @""});
    int result=openconnect_mainloop(vpn,300,5);
    emit(@{@"type":@"disconnected",@"message":@"VPN disconnected."});
    dispatch_semaphore_t removed=dispatch_semaphore_create(0);
    [network disconnect:^{ dispatch_semaphore_signal(removed); }];
    (void)dispatch_semaphore_wait(removed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    connection.invalidationHandler=nil; connection.interruptionHandler=nil; [connection invalidate];
    return result;
}
static NSDictionary *response(void) {
    // Bounded anonymous-pipe input; do not place secrets in argv, files or logs.
    char *line = calloc(65538, 1); size_t count = 0;
    while (count < 65536) {
        struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
        if (poll(&p, 1, 300000) <= 0) break;
        char c; if (read(STDIN_FILENO, &c, 1) != 1) break;
        if (c == '\n') {
            NSData *data = [NSData dataWithBytesNoCopy:line length:count freeWhenDone:NO];
            id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            memset_s(line, 65538, 0, 65538); free(line);
            return [result isKindOfClass:NSDictionary.class] ? result : nil;
        }
        line[count++] = c;
    }
    memset_s(line, 65538, 0, 65538); free(line); return nil;
}
static int form(void *context, struct oc_auth_form *form) {
    @autoreleasepool {
        NSMutableArray *fields = NSMutableArray.array;
        NSMutableSet *names = NSMutableSet.set;
        for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
            if (opt->flags & OC_FORM_OPT_IGNORE || opt->type == OC_FORM_OPT_HIDDEN || opt->type == OC_FORM_OPT_SSO_TOKEN || opt->type == OC_FORM_OPT_SSO_USER) continue;
            NSString *name = text(opt->name);
            if (!name.length || [names containsObject:name]) return OC_FORM_RESULT_ERR;
            [names addObject:name];
            NSString *kind;
            if (opt->type == OC_FORM_OPT_PASSWORD || opt->type == OC_FORM_OPT_TOKEN) kind = @"password";
            else if (opt->type == OC_FORM_OPT_TEXT) kind = @"text";
            else if (opt->type == OC_FORM_OPT_SELECT) kind = @"select";
            else { emit(@{@"type":@"error", @"message":@"This gateway requires an authentication method that Relay does not support yet."}); return OC_FORM_RESULT_ERR; }
            NSMutableArray *choices = NSMutableArray.array;
            if (opt->type == OC_FORM_OPT_SELECT) {
                struct oc_form_opt_select *select = (void *)opt;
                if (select->nr_choices > 128) return OC_FORM_RESULT_ERR;
                for (int i = 0; i < select->nr_choices; i++) {
                    struct oc_choice *choice = select->choices[i];
                    [choices addObject:@{@"value":text(choice->name), @"label":text(choice->label ?: choice->name)}];
                }
            }
            NSString *initial = @"";
            if (opt->type == OC_FORM_OPT_SELECT) {
                struct oc_form_opt_select *select = (void *)opt;
                if (select == form->authgroup_opt && form->authgroup_selection >= 0 && form->authgroup_selection < select->nr_choices)
                    initial = text(select->choices[form->authgroup_selection]->name);
                else if (choices.count) initial = choices[0][@"value"];
            }
            [fields addObject:@{@"id":text(opt->name), @"label":text(opt->label ?: opt->name), @"kind":kind, @"choices":choices, @"initial":initial}];
            if (fields.count > 32) return OC_FORM_RESULT_ERR;
        }
        if (!fields.count) return OC_FORM_RESULT_OK;
        int identifier = ++sequence;
        emit(@{@"type":@"form", @"id":@(identifier), @"message":text(form->message), @"banner":text(form->banner), @"error":text(form->error), @"fields":fields});
        NSDictionary *reply = response();
        if (!reply || [reply[@"cancel"] boolValue] || [reply[@"id"] intValue] != identifier) return OC_FORM_RESULT_CANCELLED;
        NSDictionary *values = reply[@"values"];
        if (![values isKindOfClass:NSDictionary.class]) return OC_FORM_RESULT_ERR;
        for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
            if (opt->flags & OC_FORM_OPT_IGNORE || opt->type == OC_FORM_OPT_HIDDEN || opt->type == OC_FORM_OPT_SSO_TOKEN || opt->type == OC_FORM_OPT_SSO_USER) continue;
            NSString *value = values[text(opt->name)];
            if (![value isKindOfClass:NSString.class] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192) return OC_FORM_RESULT_ERR;
            if (opt->type == OC_FORM_OPT_SELECT) {
                struct oc_form_opt_select *select = (void *)opt;
                int match = -1;
                for (int i = 0; i < select->nr_choices; i++) if ([value isEqualToString:text(select->choices[i]->name)]) match = i;
                if (match < 0) return OC_FORM_RESULT_ERR;
                if (select == form->authgroup_opt && match != form->authgroup_selection) {
                    if (openconnect_set_option_value(opt, value.UTF8String)) return OC_FORM_RESULT_ERR;
                    return OC_FORM_RESULT_NEWGROUP;
                }
            }
            if (openconnect_set_option_value(opt, value.UTF8String)) return OC_FORM_RESULT_ERR;
        }
        emit(@{@"type":@"progress", @"message":@"Verifying sign-in…"});
        return OC_FORM_RESULT_OK;
    }
}
static int certificate(void *context, const char *reason) {
    emit(@{@"type":@"error", @"message":@"The VPN server certificate could not be verified."});
    return -1; // Never override failed system/library certificate validation.
}
static void progress(void *context, int level, const char *format, ...) { /* Raw library messages may contain secrets. */ }
static int browser(struct openconnect_info *vpn, const char *uri, void *context) {
    NSURL *url=uri ? [NSURL URLWithString:@(uri)] : nil;
    if(![url.scheme isEqual:@"https"] || !url.host.length || url.user || url.password || strlen(uri)>16384) return -1;
    emit(@{@"type":@"browser",@"url":@(uri),@"message":@"Complete sign-in in your browser."});
    return 0;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if ((argc != 2 && argc != 3) || getuid() == 0) return 2;
        BOOL connect=argc==3 && !strcmp(argv[2],"--connect");
        if(argc==3 && !connect) return 2;
        NSURL *url = [NSURL URLWithString:@(argv[1])];
        if (![url.scheme isEqualToString:@"https"] || !url.host.length || url.user || url.password || url.query || url.fragment) return 2;
        openconnect_init_ssl();
        struct openconnect_info *vpn = openconnect_vpninfo_new("Relay VPN", certificate, NULL, form, progress, NULL);
        if (!vpn) return 2;
        commandFD=openconnect_setup_cmd_pipe(vpn);
        signal(SIGTERM,cancelSignal); signal(SIGINT,cancelSignal);
        openconnect_set_external_browser_callback(vpn, browser);
        openconnect_set_loglevel(vpn, PRG_ERR);
        int result = openconnect_set_protocol(vpn, "anyconnect");
        if (!result) result = openconnect_parse_url(vpn, argv[1]);
        emit(@{@"type":@"progress", @"message":@"Contacting VPN gateway…"});
        if (!result) result = openconnect_obtain_cookie(vpn);
        if (!result && connect) result=tunnel(vpn);
        else if (!result) emit(@{@"type":@"authenticated", @"message":@"Sign-in verified."});
        else if (result != OC_FORM_RESULT_CANCELLED) emit(@{@"type":@"error", @"message":@"Sign-in did not complete. Check the gateway and try again."});
        commandFD=-1;
        openconnect_clear_cookie(vpn);
        openconnect_vpninfo_free(vpn);
        return result ? 1 : 0;
    }
}
