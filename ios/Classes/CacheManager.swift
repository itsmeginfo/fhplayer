import AVKit
import Cache
import GCDWebServer
import PINCache
import AVFoundation

@objc public class CacheManager: NSObject {
    
    // We store the last pre-cached CachingPlayerItem objects to be able to play even if the download
    // has not finished.
    var _preCachedURLs = Dictionary<String, CachingPlayerItem>()

    var completionHandler: ((_ success:Bool) -> Void)? = nil

    var diskConfig = DiskConfig(name: "BetterPlayerCache", expiry: .date(Date().addingTimeInterval(3600*24*30)),
                                maxSize: 100*1024*1024)
    
    // Flag whether the CachingPlayerItem was already cached.
    var _existsInStorage: Bool = false
    
    let memoryConfig = MemoryConfig(
      // Expiry date that will be applied by default for every added object
      // if it's not overridden in the `setObject(forKey:expiry:)` method
      expiry: .never,
      // The maximum number of objects in memory the cache should hold
      countLimit: 0,
      // The maximum total cost that the cache can hold before it starts evicting objects, 0 for no limit
      totalCostLimit: 0
    )
    
    var server: HLSCachingReverseProxyServer?
    
    private var loaderDelegate: BetterPlayerEzDrmAssetsLoaderDelegate?
    
    lazy var storage: Cache.Storage<String,Data>? = {
        return try? Cache.Storage<String,Data>(diskConfig: diskConfig, memoryConfig: memoryConfig, transformer: TransformerFactory.forCodable(ofType: Data.self))
    }()
    

    ///Setups cache server for HLS streams
    @objc public func setup(){
        GCDWebServer.setLogLevel(4)
        let webServer = GCDWebServer()
        let cache = PINCache.shared
        let urlSession = URLSession.shared
        server = HLSCachingReverseProxyServer(webServer: webServer, urlSession: urlSession, cache: cache)
        server?.start(port: 8080)
    }
    
    @objc public func setMaxCacheSize(_ maxCacheSize: NSNumber?){
        if let unsigned = maxCacheSize {
            let _maxCacheSize = unsigned.uintValue
            diskConfig = DiskConfig(name: "BetterPlayerCache", expiry: .date(Date().addingTimeInterval(3600*24*30)), maxSize: _maxCacheSize)
        }        
    }

    // MARK: - Logic
    @objc public func preCacheURL(_ url: URL, cacheKey: String?, videoExtension: String?, withHeaders headers: Dictionary<NSObject,AnyObject>, completionHandler: ((_ success:Bool) -> Void)?) {
        self.completionHandler = completionHandler
        
        let _key: String = cacheKey ?? url.absoluteString
        // Make sure the item is not already being downloaded
        if self._preCachedURLs[_key] == nil {            
            if let item = self.getCachingPlayerItem(url, cacheKey: _key, videoExtension: videoExtension, headers: headers){
                if !self._existsInStorage {
                    self._preCachedURLs[_key] = item
                    item.download()
                } else {
                    self.completionHandler?(true)
                }
            } else {
                self.completionHandler?(false)
            }
        } else {
            self.completionHandler?(true)
        }
    }
    
    @objc public func stopPreCache(_ url: URL, cacheKey: String?, completionHandler: ((_ success:Bool) -> Void)?){
        let _key: String = cacheKey ?? url.absoluteString
        if self._preCachedURLs[_key] != nil {
            let playerItem = self._preCachedURLs[_key]!
            playerItem.stopDownload()
            self._preCachedURLs.removeValue(forKey: _key)
            self.completionHandler?(true)
            return
        }
        self.completionHandler?(false)
    }
    
    ///Gets caching player item for normal playback.
    @objc public func getCachingPlayerItemForNormalPlayback(_ url: URL, cacheKey: String?, videoExtension: String?, headers: [NSObject:AnyObject], certificateUrl: String?, licenseUrl: String?) -> AVPlayerItem? {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        
        if mimeTypeResult.1 == "application/vnd.apple.mpegurl" {
            // Reverse proxy URL létrehozása
            if let reverseProxyURL = server?.reverseProxyURL(from: url) {
                // AVURLAsset létrehozása
                let asset = AVURLAsset(url: reverseProxyURL)
                // DRM-kezelés hozzáadása a Swift kódban, ha szükséges
                if let certificateUrl = certificateUrl, !certificateUrl.isEmpty {
                    if let authValue = headers["Authorization" as NSObject] {
                        let components = authValue.components(separatedBy: " ")
                        var bearerToken = ""
                        
                        if components.count >= 2 {
                            bearerToken = components[1]
                        }
                        
                        guard let certificateNSURL = URL(string: certificateUrl) else {
                            // Kezelés, ha a URL nem érvényes
                            return nil
                        }
                        
                        var licenseNSURL: URL?
                        
                        if let licenseUrl = licenseUrl, !licenseUrl.isEmpty {
                            licenseNSURL = URL(string: licenseUrl)
                        } else {
                            // Kezeljük az NSNull vagy nil értéket, például adjunk neki alapértelmezett értéket
                            print("A licenseUrl nil vagy NSNull, alapértelmezett érték használva")
                            // Adj hozzá alapértelmezett URL-t vagy kezelje a helyzetet más módon
                        }
                        
                        loaderDelegate = BetterPlayerEzDrmAssetsLoaderDelegate(certificateURL: certificateNSURL, licenseURL: licenseNSURL, bearerToken: bearerToken)
                        
                        // Asset resource loader delegate hozzárendelése
                        asset.resourceLoader.setDelegate(loaderDelegate, queue: DispatchQueue(label: "streamQueue"))
                    }
                }
                
                // AVPlayerItem létrehozása
                let playerItem = AVPlayerItem(asset: asset)
                return playerItem
            }
        } else {
            // DRM-kezelés Swift kódban, ha nem a cache részágban van
            return getCachingPlayerItem(url, cacheKey: cacheKey, videoExtension: videoExtension, headers: headers)
        }
        
        return nil
    }

    

    // Get a CachingPlayerItem either from the network if it's not cached or from the cache.
    @objc public func getCachingPlayerItem(_ url: URL, cacheKey: String?,videoExtension: String?, headers: Dictionary<NSObject,AnyObject>) -> CachingPlayerItem? {
        let playerItem: CachingPlayerItem
        let _key: String = cacheKey ?? url.absoluteString
        // Fetch ongoing pre-cached url if it exists
        if self._preCachedURLs[_key] != nil {
            playerItem = self._preCachedURLs[_key]!
            self._preCachedURLs.removeValue(forKey: _key)
        } else {
            // Trying to retrieve a track from cache syncronously
            let data = try? storage?.object(forKey: _key)
            if data != nil {
                // The file is cached.
                self._existsInStorage = true
                let mimeTypeResult = getMimeType(url:url, explicitVideoExtension: videoExtension)
                if (mimeTypeResult.1.isEmpty){
                    NSLog("Cache error: couldn't find mime type for url: \(url.absoluteURL). For this URL cache didn't work and video will be played without cache.")
                    playerItem = CachingPlayerItem(url: url, cacheKey: _key, headers: headers)
                } else {
                    // ISM Smooth Streaming típus esetén
                    if mimeTypeResult.1 == "application/vnd.ms-sstr+xml" {
                        playerItem = CachingPlayerItem(url: url, cacheKey: _key, headers: headers)
                    } else {
                        playerItem = CachingPlayerItem(data: data!, mimeType: "application/vnd.apple.mpegurl", fileExtension: "m3u8")
                    }
                }
            } else {
                // The file is not cached.
                playerItem = CachingPlayerItem(url: url, cacheKey: _key, headers: headers)
                self._existsInStorage = false
            }
        }
        
        playerItem.delegate = self
        return playerItem
    }

    
    // Remove all objects
    @objc public func clearCache(){
        try? storage?.removeAll()
        self._preCachedURLs = Dictionary<String,CachingPlayerItem>()
    }
    
    private func getMimeType(url: URL, explicitVideoExtension: String?) -> (String, String) {
        if url.pathComponents.last?.contains("m3u8") == true {
            return ("m3u8", "application/vnd.apple.mpegurl")
        }
        
        var videoExtension = url.pathExtension
        if let explicitVideoExtension = explicitVideoExtension {
            videoExtension = explicitVideoExtension
        }
        var mimeType = ""

        switch videoExtension.lowercased() {
        case "m3u", "m3u8":
            mimeType = "application/vnd.apple.mpegurl"
        case "3gp":
            mimeType = "video/3gpp"
        case "mp4", "m4a", "m4p", "m4b", "m4r", "m4v":
            mimeType = "video/mp4"
        case "m1v", "mpg", "mp2", "mpeg", "mpe", "mpv":
            mimeType = "video/mpeg"
        case "ogg":
            mimeType = "video/ogg"
        case "mov", "qt":
            mimeType = "video/quicktime"
        case "webm":
            mimeType = "video/webm"
        case "asf", "wma", "wmv":
            mimeType = "video/ms-asf"
        case "avi":
            mimeType = "video/x-msvideo"
        default:
            mimeType = ""
        }

        if mimeType.isEmpty {
            // ISM Smooth Streaming MIME típus
            mimeType = "application/vnd.ms-sstr+xml"
        }

        return (videoExtension, mimeType)
    }

    
    ///Checks wheter pre cache is supported for given url.
    @objc public func isPreCacheSupported(url: URL, videoExtension: String?) -> Bool{
        let mimeTypeResult = getMimeType(url:url, explicitVideoExtension: videoExtension)
        return !mimeTypeResult.1.isEmpty && mimeTypeResult.1 != "application/vnd.apple.mpegurl"
    }
}

// MARK: - CachingPlayerItemDelegate
extension CacheManager: CachingPlayerItemDelegate {
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data) {
        // A track is downloaded. Saving it to the cache asynchronously.
        storage?.async.setObject(data, forKey: playerItem.cacheKey ?? playerItem.url.absoluteString, completion: { _ in })
        self.completionHandler?(true)
    }

     func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int){
        /// Is called every time a new portion of data is received.
        let percentage = Double(bytesDownloaded)/Double(bytesExpected)*100.0
        let str = String(format: "%.1f%%", percentage)
        //NSLog("Downloading... %@", str)
    }

    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error){
        /// Is called on downloading error.
        NSLog("Error when downloading the file %@", error as NSError);
        self.completionHandler?(false)
    }
}


class BetterPlayerEzDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    var assetId: String = ""
    var license: Data?

    let DEFAULT_LICENSE_SERVER_URL = "https://fps.ezdrm.com/api/licenses/"
    var certificateURL: URL
    var licenseURL: URL?
    var bearerToken: String

    init(certificateURL: URL, licenseURL: URL?, bearerToken: String) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.bearerToken = bearerToken
        super.init()
    }

    typealias DataCompletionBlock = (Data?, Error?) -> Void

    func getContentKeyAndLeaseExpiryFromKeyServerModule(with requestBytes: Data, assetId: String, contentId: String, completion: @escaping DataCompletionBlock) {
        var finalLicenseURL: URL
        if let licenseURL = licenseURL {
            finalLicenseURL = licenseURL
        } else {
            finalLicenseURL = URL(string: DEFAULT_LICENSE_SERVER_URL)!
        }

        var request = URLRequest(url: finalLicenseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-type")

        if !bearerToken.isEmpty {
            let authorizationHeader = "Bearer " + bearerToken
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        let stringBody = "spc=\(requestBytes.base64EncodedString())&assetId=\(contentId)"
        let body = stringBody.data(using: .utf8)
        request.httpBody = body

        let session = URLSession.shared
        let dataTask = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(nil, error)
            } else if let data = data {
                if let str = String(data: data, encoding: .utf8),
                   let startRange = str.range(of: "<ckc>"),
                   let endRange = str.range(of: "</ckc>") {
                    let startIndex = startRange.upperBound
                    let endIndex = endRange.lowerBound
                    let strippedString = String(str[startIndex..<endIndex])

                    if let decodedData = Data(base64Encoded: strippedString)
                    {
                            completion(decodedData, nil)
                    }
                    
                } else {
                    completion(nil, nil) // Handle parsing error
                }
            }
        }

        dataTask.resume()
    }
    
    func getAppCertificate(_ string: String) throws -> Data? {
        do {
            let certificate = try Data(contentsOf: certificateURL)
            license = certificate
            return certificate
        } catch {
            return nil
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let assetURI = loadingRequest.request.url
        let str = assetURI?.absoluteString ?? ""
        let contentId = assetURI?.host ?? ""
        let mySubstring = String(str.suffix(36))
        assetId = mySubstring
        let scheme = assetURI?.scheme ?? ""

        guard scheme == "skd" else {
            return false
        }

        do {
            guard let certificate = try getAppCertificate(assetId) else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRejected, userInfo: nil)
            }

            let requestBytes = try loadingRequest.streamingContentKeyRequestData(forApp: certificate, contentIdentifier: str.data(using: .utf8)!, options: nil)
            let passthruParams = "?customdata=\(assetId)"

            getContentKeyAndLeaseExpiryFromKeyServerModule(with: requestBytes, assetId: assetId, contentId: contentId) { (data, error) in
                if let error = error {
                    // Handle the error
                    print("Error: \(error)")
                } else if let data = data {
                    let dataRequest = loadingRequest.dataRequest
                    let requestedRange = NSRange(location: Int(dataRequest!.requestedOffset), length: data.count)
                    let dataInRange = data.subdata(in: Range(requestedRange)!)
                    dataRequest!.respond(with: dataInRange)
                    loadingRequest.finishLoading()
                }
            }
        } catch {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: nil))
            return true
        }

        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest) -> Bool {
        return shouldWaitForLoadingOfRequestedResource(resourceLoader, loadingRequest: renewalRequest as AVAssetResourceLoadingRequest)
    }

    func shouldWaitForLoadingOfRequestedResource(_ resourceLoader: AVAssetResourceLoader, loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // A logika, amit alkalmazni szeretnél
        // ...
        return true
    }


}
