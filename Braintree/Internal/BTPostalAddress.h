#import <Foundation/Foundation.h>
#import "BTNullability.h"

BT_ASSUME_NONNULL_BEGIN

@interface BTPostalAddress : NSObject <NSCopying>

/// Optional. Recipient name for shipping address.
@property (nonatomic, BT_NULLABLE, copy) NSString *recipientName;

/// Line 1 of the Address (eg. number, street, etc).
@property (nonatomic, copy) NSString *streetAddress;

/// Optional line 2 of the Address (eg. suite, apt #, etc.).
@property (nonatomic, BT_NULLABLE, copy) NSString *extendedAddress;

/// City name.
@property (nonatomic, copy) NSString *locality;

/// 2 letter country code.
@property (nonatomic, copy) NSString *countryCodeAlpha2;

/// Zip code or equivalent is usually required for countries that have them. For list of countries that do not have postal codes please refer to http://en.wikipedia.org/wiki/Postal_code.
@property (nonatomic, BT_NULLABLE, copy) NSString *postalCode;

/// 2 letter code for US states, and the equivalent for other countries.
@property (nonatomic, BT_NULLABLE, copy) NSString *region;

@end

BT_ASSUME_NONNULL_END
