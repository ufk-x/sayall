#import <Foundation/Foundation.h>

// Returns only button usages and connection events for the configured remote.
static inline NSString *RKDecodeLine(NSString *line, NSString *address) {
    NSArray<NSString *> *p=[line componentsSeparatedByString:@"\t"];
    if(p.count<6 || ![p[2].uppercaseString isEqualToString:address]) return nil;
    NSString *type=p[1];
    if([type isEqualToString:@"Config"]) return @"TARGET\n";
    NSScanner *scanner=[NSScanner scannerWithString:p[5]];
    unsigned char raw[4096]; NSUInteger n=0; unsigned value;
    while(!scanner.isAtEnd) {
        if(n==sizeof(raw) || ![scanner scanHexInt:&value] || value>255) return nil;
        raw[n++]=(unsigned char)value;
    }
    if([type isEqualToString:@"HCI Event"]) {
        if(n==6 && raw[0]==5 && raw[1]==4) return @"RELEASE\n";
        return nil;
    }
    if(![type isEqualToString:@"ATT Receive"] && ![type isEqualToString:@"ACL Receive"]) return nil;
    if(n<9 || (raw[0]|raw[1]<<8)>>12 != 2 || (NSUInteger)(raw[2]|raw[3]<<8)!=n-4 ||
       (NSUInteger)(raw[4]|raw[5]<<8)!=n-8 || raw[6]!=4 || raw[7]!=0) return nil;
    if(raw[8]!=0x1b || n<11 || raw[9]!=0x2b || raw[10]!=0) return nil;
    if(n!=13) return @"RELEASE\n"; // A changed format must never leave a held key behind.
    unsigned usage=raw[11]|raw[12]<<8;
    return [NSString stringWithFormat:@"U %u\n",usage];
}
