// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayerEzDrmAssetsLoaderDelegate.h"

@implementation BetterPlayerEzDrmAssetsLoaderDelegate

NSString *_assetId;
NSData *_license;

NSString * DEFAULT_LICENSE_SERVER_URL = @"https://fps.ezdrm.com/api/licenses/";

- (instancetype)init:(NSURL *)certificateURL withLicenseURL:(NSURL *)licenseURL bearerToken:(NSString *)bearerToken {
    if (self = [super init]) {
        _certificateURL = certificateURL;
        _licenseURL = licenseURL;
        // Ellenőrizzük, hogy a bearerToken nem nil és nem üres string
        if (bearerToken && ![bearerToken isEqualToString:@""]) {
            // Az érték érvényes, használhatjuk
            _bearerToken = bearerToken;
        } else {
            // Ha nil vagy üres, kezeljük ezt az esetet (pl. adjunk neki alapértelmezett értéket)
            _bearerToken = @"defaultBearerToken";
            NSLog(@"Az érték nil vagy üres string, alapértelmezett érték használva");
        }

        // További inicializációk...
    }
    return self;
}
/*------------------------------------------
 **
 ** getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest
 **
 ** Takes the bundled SPC and sends it to the license server defined at licenseUrl or KEY_SERVER_URL (if licenseUrl is null).
 ** It returns CKC.
 ** ---------------------------------------*/
typedef void (^DataCompletionBlock)(NSData *data, NSError *error);

- (void)getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest:(NSData *)requestBytes
                                                            and:(NSString *)assetId
                                                            and:(NSString *)contentId
                                                       completion:(DataCompletionBlock)completionHandler {
    NSURL *finalLicenseURL;
    // Check for _licenseURL, set finalLicenseURL accordingly
    if (_licenseURL != [NSNull null]) {
        finalLicenseURL = _licenseURL;
    } else {
        finalLicenseURL = [NSURL URLWithString:DEFAULT_LICENSE_SERVER_URL];
    }
    NSURL *ksmURL = finalLicenseURL;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ksmURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-type"];
    if ([_bearerToken length] != 0) {
        NSString *authorizationHeader = [NSString stringWithFormat:@"Bearer %@", _bearerToken];
        [request setValue:authorizationHeader forHTTPHeaderField:@"Authorization"];
    }

    NSString *stringBody = [NSString stringWithFormat:@"spc=%@&assetId=%@", [requestBytes base64EncodedStringWithOptions:0], contentId];
    NSData *body = [stringBody dataUsingEncoding:NSUTF8StringEncoding];
    [request setHTTPBody:body];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"Error: %@", error);
            completionHandler(nil, error);
        } else {
            NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSRange startRange = [str rangeOfString:@"<ckc>"];
            NSRange endRange = [str rangeOfString:@"</ckc>"];
            if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                NSInteger startIndex = startRange.location + startRange.length;
                NSInteger endIndex = endRange.location;
                NSString *strippedString = [str substringWithRange:NSMakeRange(startIndex, endIndex - startIndex)];

                // Base64 decoding
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:strippedString options:0];

                // Extract bytes from NSData
                const char *bytes = [decodedData bytes];
                NSData *resultData = [NSData dataWithBytes:bytes length:decodedData.length];
                completionHandler(resultData, nil);
            }
        }
    }];

    [dataTask resume];
}


/*------------------------------------------
 **
 ** getAppCertificate
 **
 ** returns the apps certificate for authenticating against your server
 ** the example here uses a local certificate
 ** but you may need to edit this function to point to your certificate
 ** ---------------------------------------*/
- (NSData *)getAppCertificate:(NSString *) String {
    NSData * certificate = nil;
    certificate = [NSData dataWithContentsOfURL:_certificateURL];
    _license = certificate;
    return certificate;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *assetURI = loadingRequest.request.URL;
    NSString * str = assetURI.absoluteString;
    NSString *contentId = assetURI.host;
    NSString * mySubstring = [str substringFromIndex:str.length - 36];
    _assetId = mySubstring;
    NSString * scheme = assetURI.scheme;
    NSData * requestBytes;
    NSData * certificate;
    if (!([scheme isEqualToString: @"skd"])){
        return NO;
    }
    @try {
        certificate = [self getAppCertificate:_assetId];
    }
    @catch (NSException* excp) {
        [loadingRequest finishLoadingWithError:[[NSError alloc] initWithDomain:NSURLErrorDomain code:NSURLErrorClientCertificateRejected userInfo:nil]];
    }
    @try {
        requestBytes = [loadingRequest streamingContentKeyRequestDataForApp:certificate contentIdentifier: [str dataUsingEncoding:NSUTF8StringEncoding] options:nil error:nil];
    }
    @catch (NSException* excp) {
        [loadingRequest finishLoadingWithError:nil];
        return YES;
    }
    
    NSString * passthruParams = [NSString stringWithFormat:@"?customdata=%@", _assetId];
    NSData * responseData;
    NSError * error;
    
    [self getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest:requestBytes and:_assetId and:contentId completion:^(NSData *data, NSError *error) {
        if (error) {
            // Handle the error
        } else {
            AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
            NSRange requestedRange = NSMakeRange((NSUInteger)dataRequest.requestedOffset, data.length);
            NSData *dataInRange = [data subdataWithRange:requestedRange];
            [dataRequest respondWithData:dataInRange];
            [loadingRequest finishLoading];
        }
    }];
    
    
    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self resourceLoader:resourceLoader shouldWaitForLoadingOfRequestedResource:renewalRequest];
}

@end
