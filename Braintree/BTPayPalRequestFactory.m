#import "BTPayPalRequestFactory.h"

@implementation BTPayPalRequestFactory

/// Creates checkout (Single Payments) requests for PayPal
- (PayPalOneTouchCheckoutRequest *)requestWithApprovalURL:(NSURL *)approvalURL
                                                 clientID:(NSString *)clientID
                                              environment:(NSString *)environment
                                        callbackURLScheme:(NSString *)callbackURLScheme
{
    return [PayPalOneTouchCheckoutRequest requestWithApprovalURL:approvalURL
                                                        clientID:clientID
                                                     environment:environment
                                               callbackURLScheme:callbackURLScheme];
}

/// Creates authorization (Future Payments) requests for PayPal
- (PayPalOneTouchAuthorizationRequest *)requestWithScopeValues:(NSSet *)scopeValues
                                                    privacyURL:(NSURL *)privacyURL
                                                  agreementURL:(NSURL *)agreementURL
                                                      clientID:(NSString *)clientID
                                                   environment:(NSString *)environment
                                             callbackURLScheme:(NSString *)callbackURLScheme
{
    return [PayPalOneTouchAuthorizationRequest requestWithScopeValues:scopeValues
                                                           privacyURL:privacyURL
                                                         agreementURL:agreementURL
                                                             clientID:clientID
                                                          environment:environment
                                                    callbackURLScheme:callbackURLScheme];
}

@end
