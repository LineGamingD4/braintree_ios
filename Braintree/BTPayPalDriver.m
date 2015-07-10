#import "BTPayPalDriver_Internal.h"

#import "PayPalOneTouchRequest.h"
#import "PayPalOneTouchCore.h"

#import "BTAPIClient_Internal.h"
#import "BTAnalyticsClient.h"
#import "BTAPIClient.h"
#import "BTTokenizedPayPalAccount_Internal.h"
#import "BTTokenizedPayPalCheckout_Internal.h"
#import "BTPostalAddress_Internal.h"
#import "BTLogger_Internal.h"

NSString *const BTPayPalDriverErrorDomain = @"com.braintreepayments.BTPayPalDriverErrorDomain";

static void (^appSwitchReturnBlock)(NSURL *url);

@interface BTPayPalDriver ()
@property (nonatomic, strong) BTAPIClient *apiClient;
@property (nonatomic, copy) NSString *returnURLScheme;
@end

@implementation BTPayPalDriver

- (nonnull instancetype)initWithAPIClient:(nonnull BTAPIClient *)apiClient returnURLScheme:(NSString *)returnURLScheme {
    self = [super init];
    if (self) {
        _apiClient = apiClient;
        _returnURLScheme = returnURLScheme;
    }
    return self;
}

#pragma mark - Authorization (Future Payments)

- (void)authorizeAccountWithCompletion:(void (^)(BTTokenizedPayPalAccount *paymentMethod, NSError *error))completionBlock {
    [self authorizeAccountWithAdditionalScopes:[NSSet set] completion:completionBlock];
}

- (void)authorizeAccountWithAdditionalScopes:(NSSet<NSString *> *)additionalScopes completion:(void (^)(BTTokenizedPayPalAccount *, NSError *))completionBlock {

    [self setAuthorizationAppSwitchReturnBlock:completionBlock];

    [self.apiClient fetchOrReturnRemoteConfiguration:^(BTJSON *remoteConfiguration, NSError *error) {
        if (error) {
            if (completionBlock) completionBlock(nil, error);
            return;
        }
        if (!remoteConfiguration[@"paypalEnabled"].isTrue) {
            error = [NSError errorWithDomain:BTPayPalDriverErrorDomain code:BTPayPalDriverErrorTypeDisabled userInfo:nil];
            if (completionBlock) completionBlock(nil, error);
            return;
        }

        PayPalOneTouchAuthorizationRequest *request =
        [self.requestFactory requestWithScopeValues:[self.defaultOAuth2Scopes setByAddingObjectsFromSet:(additionalScopes ? additionalScopes : [NSSet set])]
                                         privacyURL:remoteConfiguration[@"paypal"][@"privacyUrl"].asURL
                                       agreementURL:remoteConfiguration[@"paypal"][@"userAgreementUrl"].asURL
                                           clientID:[self paypalClientIdWithRemoteConfiguration:remoteConfiguration]
                                        environment:[self payPalEnvironmentForRemoteConfiguration:remoteConfiguration]
                                  callbackURLScheme:self.returnURLScheme];

        // At this time, the Braintree client_token is required by the temporary Braintree Future Payments consent webpage.
        request.additionalPayloadAttributes = @{ @"client_token": self.clientToken };

        [self informDelegateWillPerformAppSwitch];
        [request performWithCompletionBlock:^(BOOL success, PayPalOneTouchRequestTarget target, NSError *error) {
            [self postAnalyticsEventForInitiatingOneTouchWithSuccess:success target:target];
            if (success) {
                [self informDelegateDidPerformAppSwitchToTarget:target];
            } else {
                if (completionBlock) completionBlock(nil, error);
            }
        }];
    }];
}

- (void)setAuthorizationAppSwitchReturnBlock:(void (^)(BTTokenizedPayPalAccount *account, NSError *error))completionBlock {
    appSwitchReturnBlock = ^(NSURL *url){
        [self informDelegateWillProcessAppSwitchResult];

        [self.payPalClass parseResponseURL:url
                           completionBlock:^(PayPalOneTouchCoreResult *result) {
                               [self postAnalyticsEventForHandlingOneTouchResult:result];

                               switch (result.type) {
                                   case PayPalOneTouchResultTypeError:
                                       if (completionBlock) completionBlock(nil, result.error);
                                       break;
                                   case PayPalOneTouchResultTypeCancel:
                                       if (result.error) {
                                           // TODO: Log error
                                           return;
                                       }
                                       if (completionBlock) completionBlock(nil, nil);
                                       break;
                                   case PayPalOneTouchResultTypeSuccess: {
                                       BTClientMetadata *clientMetadata = [self clientMetadataForResult:result];
                                       [self.apiClient POST:@"/v1/payment_methods/paypal_accounts"
                                                 parameters:@{ @"paypal_account": result.response,
                                                               @"correlation_id": [PayPalOneTouchCore clientMetadataID],
                                                               @"_meta": @{ @"source": clientMetadata.sourceString,
                                                                            @"integration": clientMetadata.integrationString } }
                                                 completion:^(BTJSON *body, NSHTTPURLResponse *response, NSError *error) {
                                                     if (error) {
                                                         [self postAnalyticsEventForTokenizationFailure];
                                                         if (completionBlock) completionBlock(nil, error);
                                                         return;
                                                     }

                                                     [self postAnalyticsEventForTokenizationSuccess];

                                                     BTPostalAddress *accountAddress = [self accountAddressFromJSON:body[@"paypalAccounts"][0][@"details"][@"payerInfo"][@"accountAddress"]];
                                                     NSString *nonce = body[@"paypalAccounts"][0][@"nonce"].asString;
                                                     NSString *email = body[@"paypalAccounts"][0][@"email"].asString;

                                                     BTTokenizedPayPalAccount *tokenizedPayPalAccount = [[BTTokenizedPayPalAccount alloc] initWithPaymentMethodNonce:nonce description:email email:email accountAddress:accountAddress];

                                                     if (completionBlock) completionBlock(tokenizedPayPalAccount, nil);
                                                     appSwitchReturnBlock = nil;
                                                 }];
                                       break;
                                   }
                               }
                           }];
    };
}



#pragma mark - Checkout (Single Payments)

- (void)checkoutWithCheckoutRequest:(BTPayPalCheckoutRequest *)checkoutRequest completion:(void (^)(BTTokenizedPayPalCheckout *tokenizedCheckout, NSError *error))completionBlock {
    // TODO - call completion block with error if checkoutRequest is bad/nil

    NSString *returnURI;
    NSString *cancelURI;

    ///
    /// TODO: Why aren't we getting the redirect and cancel URLs?
    ///
    [self.payPalClass redirectURLsForCallbackURLScheme:self.returnURLScheme
                                         withReturnURL:&returnURI
                                         withCancelURL:&cancelURI];

    [self.apiClient fetchOrReturnRemoteConfiguration:^(BTJSON *remoteConfiguration, NSError *error) {
        if (error) {
            if (completionBlock) completionBlock(nil, error);
            return;
        }

        NSString *currencyCode = checkoutRequest.currencyCode ?: remoteConfiguration[@"payPal"][@"currencyIsoCode"].asString;
        NSString *correlationId = @"TODO";

        [self.apiClient POST:@"v1/paypal_hermes/create_payment_resource"
                  parameters:@{ @"amount": checkoutRequest.amount.stringValue,
                                @"currency_iso_code": currencyCode ?: [NSNull null],
                                @"return_url": returnURI ?: [NSNull null],
                                @"cancel_url": cancelURI ?: [NSNull null],
                                @"correlation_id": correlationId }
                  completion:^(BTJSON *body, NSHTTPURLResponse *response, NSError *error) {

                      if (error) {
                          if (completionBlock) completionBlock(nil, error);
                          return;
                      }

                      [self setCheckoutAppSwitchReturnBlock:completionBlock];

                      NSString *payPalClientID = remoteConfiguration[@"paypal"][@"clientId"].asString;

                      if (!payPalClientID && [self payPalEnvironmentForRemoteConfiguration:remoteConfiguration] == PayPalEnvironmentMock) {
                          payPalClientID = @"FAKE-PAYPAL-CLIENT-ID";
                      }
                      PayPalOneTouchCheckoutRequest *request = [self.requestFactory requestWithApprovalURL:body[@"paymentResource"][@"redirectURL"].asURL
                                                                                                  clientID:payPalClientID
                                                                                               environment:[self payPalEnvironmentForRemoteConfiguration:remoteConfiguration]
                                                                                         callbackURLScheme:self.returnURLScheme];

                      [self informDelegateWillPerformAppSwitch];

                      [request performWithCompletionBlock:^(BOOL success, PayPalOneTouchRequestTarget target, NSError *error) {
                          [self postAnalyticsEventForSinglePaymentForInitiatingOneTouchWithSuccess:success target:target];
                          if (success) {
                              [self informDelegateDidPerformAppSwitchToTarget:target];
                          } else {
                              if (completionBlock) completionBlock(nil, error);
                          }
                      }];
                  }];
    }];
}

- (void)setCheckoutAppSwitchReturnBlock:(void (^)(BTTokenizedPayPalCheckout *tokenizedCheckout, NSError *error))completionBlock {
    appSwitchReturnBlock = ^(NSURL *url){
        [self informDelegateWillProcessAppSwitchResult];

        [self.payPalClass parseResponseURL:url
                           completionBlock:^(PayPalOneTouchCoreResult *result) {

                               [self postAnalyticsEventForSinglePaymentForHandlingOneTouchResult:result];

                               switch (result.type) {
                                   case PayPalOneTouchResultTypeError:
                                       if (completionBlock) completionBlock(nil, result.error);
                                       break;
                                   case PayPalOneTouchResultTypeCancel:
                                       if (result.error) {
                                           [[BTLogger sharedLogger] error:@"PayPal error: %@", result.error];
                                           return;
                                       }
                                       if (completionBlock) completionBlock(nil, nil);
                                       break;
                                   case PayPalOneTouchResultTypeSuccess: {

                                       NSMutableDictionary *payPalParameters = [result.response mutableCopy];
                                       payPalParameters[@"options"] = @{ @"validate": @NO };

                                       [self.apiClient POST:@"/v1/payment_methods/paypal_accounts"
                                                 parameters:@{ @"paypal_account": payPalParameters,
                                                               @"correlation_id": @"TODO" }
                                                 completion:^(BTJSON *body, NSHTTPURLResponse *response, NSError *error) {
                                                     if (error) {
                                                         [self postAnalyticsEventForTokenizationFailureForSinglePayment];
                                                         if (completionBlock) completionBlock(nil, error);
                                                         return;
                                                     }

                                                     [self postAnalyticsEventForTokenizationSuccessForSinglePayment];

                                                     BTPostalAddress *shippingAddress = [self shippingOrBillingAddressFromJSON:body[@"paypalAccounts"][0][@"details"][@"payerInfo"][@"shippingAddress"]];
                                                     BTPostalAddress *billingAddress = [self shippingOrBillingAddressFromJSON:body[@"paypalAccounts"][0][@"details"][@"payerInfo"][@"billingAddress"]];
                                                     if (!billingAddress) {
                                                         billingAddress = [self accountAddressFromJSON:body[@"paypalAccounts"][0][@"details"][@"payerInfo"][@"accountAddress"]];
                                                     }
                                                     NSString *nonce = body[@"paypalAccounts"][0][@"nonce"].asString;
                                                     NSString *email = body[@"paypalAccounts"][0][@"email"].asString;

                                                     BTTokenizedPayPalCheckout *tokenizedCheckout = [[BTTokenizedPayPalCheckout alloc] initWithPaymentMethodNonce:nonce
                                                                                                                                                      description:email
                                                                                                                                                            email:email
                                                                                                                                                        firstName:@"TODO"
                                                                                                                                                         lastName:@"TODO"
                                                                                                                                                            phone:@"TODO"
                                                                                                                                                   billingAddress:billingAddress
                                                                                                                                                  shippingAddress:shippingAddress];

                                                     if (completionBlock) completionBlock(tokenizedCheckout, nil);
                                                 }];
                                       break;
                                   }
                               }
                               appSwitchReturnBlock = nil;
                           }];
    };
}

#pragma mark - Helpers

- (NSString *)payPalEnvironmentForRemoteConfiguration:(BTJSON *)remoteConfiguration {
    NSString *btPayPalEnvironmentName = remoteConfiguration[@"paypal"][@"environment"].asString;
    if ([btPayPalEnvironmentName isEqualToString:@"offline"]) {
        return PayPalEnvironmentMock;
    } else if ([btPayPalEnvironmentName isEqualToString:@"live"]) {
        return PayPalEnvironmentProduction;
    } else {
        return btPayPalEnvironmentName;
    }
}

- (NSString *)paypalClientIdWithRemoteConfiguration:(BTJSON *)remoteConfiguration {
    if ([remoteConfiguration[@"paypal"][@"environment"].asString isEqualToString:@"offline"] && !remoteConfiguration[@"paypal"][@"clientId"].isString) {
        return @"mock-paypal-client-id";
    } else {
        return remoteConfiguration[@"paypal"][@"clientId"].asString;
    }
}

- (BTClientMetadata *)clientMetadataForResult:(PayPalOneTouchCoreResult *)result {
    BTClientMutableMetadata *metadata = [self.apiClient.metadata mutableCopy];

    if ([PayPalOneTouchCore isWalletAppInstalled]) {
        metadata.source = BTClientMetadataSourcePayPalApp;
    } else {
        metadata.source = BTClientMetadataSourcePayPalBrowser;
    }

    switch (result.target) {
        case PayPalOneTouchRequestTargetNone:
        case PayPalOneTouchRequestTargetUnknown:
            metadata.source = BTClientMetadataSourceUnknown;
            break;
        case PayPalOneTouchRequestTargetBrowser:
            metadata.source = BTClientMetadataSourcePayPalBrowser;
            break;
        case PayPalOneTouchRequestTargetOnDeviceApplication:
            metadata.source = BTClientMetadataSourcePayPalBrowser;
            break;
    }

    return [metadata copy];
}

- (BTClientMetadata *)metadataForResult:(PayPalOneTouchCoreResult *)result {
    BTClientMutableMetadata *metadata = [self.apiClient.metadata mutableCopy];
    switch (result.target) {
        case PayPalOneTouchRequestTargetNone:
        case PayPalOneTouchRequestTargetUnknown:
            metadata.source = BTClientMetadataSourceUnknown;
            break;
        case PayPalOneTouchRequestTargetBrowser:
            metadata.source = BTClientMetadataSourcePayPalBrowser;
            break;
        case PayPalOneTouchRequestTargetOnDeviceApplication:
            metadata.source = BTClientMetadataSourcePayPalBrowser;
            break;
    }
    return metadata;
}

- (NSSet *)defaultOAuth2Scopes {
    return [NSSet setWithObjects:@"https://uri.paypal.com/services/payments/futurepayments", @"email", nil];
}

- (BTPostalAddress *)accountAddressFromJSON:(BTJSON *)addressJSON {
    if (!addressJSON.isObject) {
        return nil;
    }

    BTPostalAddress *address = [[BTPostalAddress alloc] init];
    address.recipientName = addressJSON[@"recipientName"].asString; // Likely to be nil
    address.streetAddress = addressJSON[@"street1"].asString;
    address.extendedAddress = addressJSON[@"street2"].asString;
    address.locality = addressJSON[@"city"].asString;
    address.region = addressJSON[@"state"].asString;
    address.postalCode = addressJSON[@"postalCode"].asString;
    address.countryCodeAlpha2 = addressJSON[@"country"].asString;

    return address;
}

- (BTPostalAddress *)shippingOrBillingAddressFromJSON:(BTJSON *)addressJSON {
    if (!addressJSON.isObject) {
        return nil;
    }

    BTPostalAddress *address = [[BTPostalAddress alloc] init];
    address.recipientName = addressJSON[@"recipientName"].asString; // Likely to be nil
    address.streetAddress = addressJSON[@"line1"].asString;
    address.extendedAddress = addressJSON[@"line2"].asString;
    address.locality = addressJSON[@"city"].asString;
    address.region = addressJSON[@"state"].asString;
    address.postalCode = addressJSON[@"postalCode"].asString;
    address.countryCodeAlpha2 = addressJSON[@"countryCode"].asString;

    return address;
}


#pragma mark - Delegate Informers

- (void)informDelegateWillPerformAppSwitch {
    if ([self.delegate respondsToSelector:@selector(payPalDriverWillPerformAppSwitch:)]) {
        [self.delegate payPalDriverWillPerformAppSwitch:self];
    }
}

- (void)informDelegateDidPerformAppSwitchToTarget:(PayPalOneTouchRequestTarget)target {
    if ([self.delegate respondsToSelector:@selector(payPalDriver:didPerformAppSwitchToTarget:)]) {
        switch (target) {
            case PayPalOneTouchRequestTargetBrowser:
                [self.delegate payPalDriver:self didPerformAppSwitchToTarget:BTPayPalDriverAppSwitchTargetBrowser];
                break;
            case PayPalOneTouchRequestTargetOnDeviceApplication:
                [self.delegate payPalDriver:self didPerformAppSwitchToTarget:BTPayPalDriverAppSwitchTargetPayPalApp];
                break;
            default:
                // Should never happen.
                break;
        }
    }
}

- (void)informDelegateWillProcessAppSwitchResult {
    if ([self.delegate respondsToSelector:@selector(payPalDriverWillProcessAppSwitchResult:)]) {
        [self.delegate payPalDriverWillProcessAppSwitchResult:self];
    }
}

#pragma mark -

- (BOOL)verifyAppSwitchWithRemoteConfiguration:(BTJSON *)remoteConfiguration returnURLScheme:(NSString *)returnURLScheme error:(NSError * __autoreleasing *)error {

    if (!remoteConfiguration[@"paypalEnabled"].isTrue) {
        [self.analyticsClient postAnalyticsEvent:@"ios.paypal-otc.preflight.disabled"];
        if (error != NULL) {
            *error = [NSError errorWithDomain:BTPayPalDriverErrorDomain
                                         code:BTPayPalDriverErrorTypeDisabled
                                     userInfo:@{ NSLocalizedDescriptionKey: @"PayPal is not enabled for this merchant." }];
        }
        return NO;
    }

    if (returnURLScheme == nil) {
        [self.analyticsClient postAnalyticsEvent:@"ios.paypal-otc.preflight.nil-return-url-scheme"];
        if (error != NULL) {
            *error = [NSError errorWithDomain:BTPayPalDriverErrorDomain
                                         code:BTPayPalDriverErrorTypeIntegrationReturnURLScheme
                                     userInfo:@{ NSLocalizedDescriptionKey: @"PayPal app switch is missing a returnURLScheme. See +[Braintree setReturnURLScheme:]." }];
        }
        return NO;
    }

    if (![PayPalOneTouchCore doesApplicationSupportOneTouchCallbackURLScheme:returnURLScheme]) {
        [self.analyticsClient postAnalyticsEvent:@"ios.paypal-otc.preflight.invalid-return-url-scheme"];
        if (error != NULL) {
            NSString *errorMessage = [NSString stringWithFormat:@"Cannot app switch to PayPal. Verify that the return URL scheme (%@) starts with this app's bundle id, and that the PayPal app is installed.", returnURLScheme];
            *error = [NSError errorWithDomain:BTPayPalDriverErrorDomain
                                         code:BTPayPalDriverErrorTypeIntegrationReturnURLScheme
                                     userInfo:@{ NSLocalizedDescriptionKey: errorMessage }];
        }
        return NO;
    }

    return YES;
}

#pragma mark Analytics Helpers

- (BTAnalyticsClient *)analyticsClient {
    static BTAnalyticsClient *analyticsClient;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        analyticsClient = [[BTAnalyticsClient alloc] initWithAPIClient:self.apiClient];
    });
    return analyticsClient;
}

- (void)postAnalyticsEventForInitiatingOneTouchWithSuccess:(BOOL)success target:(PayPalOneTouchRequestTarget)target {
    if (success) {
        switch (target) {
            case PayPalOneTouchRequestTargetNone:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.none.initiate.started"];
            case PayPalOneTouchRequestTargetUnknown:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.initiate.started"];
            case PayPalOneTouchRequestTargetOnDeviceApplication:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.initiate.started"];
            case PayPalOneTouchRequestTargetBrowser:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.initiate.started"];
        }
    } else {
        switch (target) {
            case PayPalOneTouchRequestTargetNone:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.none.initiate.failed"];
            case PayPalOneTouchRequestTargetUnknown:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.initiate.failed"];
            case PayPalOneTouchRequestTargetOnDeviceApplication:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.initiate.failed"];
            case PayPalOneTouchRequestTargetBrowser:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.initiate.failed"];
        }
    }
}

- (void)postAnalyticsEventForHandlingOneTouchResult:(PayPalOneTouchCoreResult *)result {
    switch (result.type) {
        case PayPalOneTouchResultTypeError:
            switch (result.target) {
                case PayPalOneTouchRequestTargetNone:
                case PayPalOneTouchRequestTargetUnknown:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.failed"];
                case PayPalOneTouchRequestTargetOnDeviceApplication:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.failed"];
                case PayPalOneTouchRequestTargetBrowser:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.failed"];
            }
        case PayPalOneTouchResultTypeCancel:
            if (result.error) {
                switch (result.target) {
                    case PayPalOneTouchRequestTargetNone:
                    case PayPalOneTouchRequestTargetUnknown:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.canceled-with-error"];
                    case PayPalOneTouchRequestTargetOnDeviceApplication:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.canceled-with-error"];
                    case PayPalOneTouchRequestTargetBrowser:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.canceled-with-error"];
                }
            } else {
                switch (result.target) {
                    case PayPalOneTouchRequestTargetNone:
                    case PayPalOneTouchRequestTargetUnknown:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.canceled"];
                    case PayPalOneTouchRequestTargetOnDeviceApplication:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.canceled"];
                    case PayPalOneTouchRequestTargetBrowser:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.canceled"];
                }
            }
        case PayPalOneTouchResultTypeSuccess:
            switch (result.target) {
                case PayPalOneTouchRequestTargetNone:
                case PayPalOneTouchRequestTargetUnknown:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.unknown.succeeded"];
                case PayPalOneTouchRequestTargetOnDeviceApplication:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.appswitch.succeeded"];
                case PayPalOneTouchRequestTargetBrowser:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.webswitch.succeeded"];
            }
    }
}

- (void)postAnalyticsEventForTokenizationSuccess {
    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.tokenize.succeeded"];
}

- (void)postAnalyticsEventForTokenizationFailure {
    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-future-payments.tokenize.failed"];
}

- (void)postAnalyticsEventForTokenizationSuccessForSinglePayment {
    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.tokenize.succeeded"];
}

- (void)postAnalyticsEventForTokenizationFailureForSinglePayment {
    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.tokenize.failed"];
}

- (void)postAnalyticsEventForSinglePaymentForInitiatingOneTouchWithSuccess:(BOOL)success target:(PayPalOneTouchRequestTarget)target {
    if (success) {
        switch (target) {
            case PayPalOneTouchRequestTargetNone:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.none.initiate.started"];
            case PayPalOneTouchRequestTargetUnknown:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.initiate.started"];
            case PayPalOneTouchRequestTargetOnDeviceApplication:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.initiate.started"];
            case PayPalOneTouchRequestTargetBrowser:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.initiate.started"];
        }
    } else {
        switch (target) {
            case PayPalOneTouchRequestTargetNone:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.none.initiate.failed"];
            case PayPalOneTouchRequestTargetUnknown:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.initiate.failed"];
            case PayPalOneTouchRequestTargetOnDeviceApplication:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.initiate.failed"];
            case PayPalOneTouchRequestTargetBrowser:
                return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.initiate.failed"];
        }
    }
}

- (void)postAnalyticsEventForSinglePaymentForHandlingOneTouchResult:(PayPalOneTouchCoreResult *)result {
    switch (result.type) {
        case PayPalOneTouchResultTypeError:
            switch (result.target) {
                case PayPalOneTouchRequestTargetNone:
                case PayPalOneTouchRequestTargetUnknown:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.failed"];
                case PayPalOneTouchRequestTargetOnDeviceApplication:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.failed"];
                case PayPalOneTouchRequestTargetBrowser:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.failed"];
            }
        case PayPalOneTouchResultTypeCancel:
            if (result.error) {
                switch (result.target) {
                    case PayPalOneTouchRequestTargetNone:
                    case PayPalOneTouchRequestTargetUnknown:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.canceled-with-error"];
                    case PayPalOneTouchRequestTargetOnDeviceApplication:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.canceled-with-error"];
                    case PayPalOneTouchRequestTargetBrowser:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.canceled-with-error"];
                }
            } else {
                switch (result.target) {
                    case PayPalOneTouchRequestTargetNone:
                    case PayPalOneTouchRequestTargetUnknown:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.canceled"];
                    case PayPalOneTouchRequestTargetOnDeviceApplication:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.canceled"];
                    case PayPalOneTouchRequestTargetBrowser:
                        return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.canceled"];
                }
            }
        case PayPalOneTouchResultTypeSuccess:
            switch (result.target) {
                case PayPalOneTouchRequestTargetNone:
                case PayPalOneTouchRequestTargetUnknown:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.unknown.succeeded"];
                case PayPalOneTouchRequestTargetOnDeviceApplication:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.appswitch.succeeded"];
                case PayPalOneTouchRequestTargetBrowser:
                    return [self.analyticsClient postAnalyticsEvent:@"ios.paypal-single-payment.webswitch.succeeded"];
            }
    }
}

#pragma mark - App Switch handling

+ (BOOL)canHandleAppSwitchReturnURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication {
    return appSwitchReturnBlock != nil && [PayPalOneTouchCore canParseURL:url sourceApplication:sourceApplication];
}

+ (void)handleAppSwitchReturnURL:(NSURL *)url {
    if (appSwitchReturnBlock) {
        appSwitchReturnBlock(url);
    }
}

#pragma mark - Internal

- (BTPayPalRequestFactory *)requestFactory {
    if (!_requestFactory) {
        _requestFactory = [[BTPayPalRequestFactory alloc] init];
    }
    return _requestFactory;
}

@synthesize payPalClass = _payPalClass;

- (Class)payPalClass {
    if (!_payPalClass) {
        _payPalClass = [PayPalOneTouchCore class];
    }
    return _payPalClass;
}

- (void)setPayPalClass:(Class)payPalClass {
    if ([payPalClass isSubclassOfClass:[PayPalOneTouchCore class]]) {
        _payPalClass = payPalClass;
    }
}

@end
