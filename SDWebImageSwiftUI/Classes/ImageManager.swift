/*
 * This file is part of the SDWebImage package.
 * (c) DreamPiggy <lizhuoli1126@126.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

import SwiftUI
import SDWebImage

/// A Image observable object for handle image load process. This drive the Source of Truth for image loading status.
/// You can use `@ObservedObject` to associate each instance of manager to your View type, which update your view's body from SwiftUI framework when image was loaded.
@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
public final class ImageManager : ObservableObject {
    /// loaded image, note when progressive loading, this will published multiple times with different partial image
    @Published public var image: PlatformImage?
    /// loading error, you can grab the error code and reason listed in `SDWebImageErrorDomain`, to provide a user interface about the error reason
    @Published public var error: Error?
    /// whether network is loading or cache is querying, should only be used for indicator binding
    @Published public var isLoading: Bool = false
    /// network progress, should only be used for indicator binding
    @Published public var progress: Double = 0
    /// true means during incremental loading
    @Published public var isIncremental: Bool = false
    
    var manager: SDWebImageManager
    weak var currentOperation: SDWebImageOperation? = nil
    var isFirstLoad: Bool = true // false after first call `load()`
    var isFirstPrefetch: Bool = true // false after first call `prefetch()`
    
    var url: URL?
    var options: SDWebImageOptions
    var context: [SDWebImageContextOption : Any]?
    var successBlock: ((PlatformImage, SDImageCacheType) -> Void)?
    var failureBlock: ((Error) -> Void)?
    var progressBlock: ((Int, Int) -> Void)?
    
    /// Create a image manager for loading the specify url, with custom options and context.
    /// - Parameter url: The image url
    /// - Parameter options: The options to use when downloading the image. See `SDWebImageOptions` for the possible values.
    /// - Parameter context: A context contains different options to perform specify changes or processes, see `SDWebImageContextOption`. This hold the extra objects which `options` enum can not hold.
    public init(url: URL?, options: SDWebImageOptions = [], context: [SDWebImageContextOption : Any]? = nil) {
        self.url = url
        self.options = options
        self.context = context
        if let manager = context?[.customManager] as? SDWebImageManager {
            self.manager = manager
        } else {
            self.manager = .shared
        }
    }
    
    /// Start to load the url operation
    public func load() {
        isFirstLoad = false
        if currentOperation != nil {
            return
        }
        self.isLoading = true
        currentOperation = manager.loadImage(with: url, options: options, context: context, progress: { [weak self] (receivedSize, expectedSize, _) in
            guard let self = self else {
                return
            }
            let progress: Double
            if (expectedSize > 0) {
                progress = Double(receivedSize) / Double(expectedSize)
            } else {
                progress = 0
            }
            DispatchQueue.main.async {
                self.progress = progress
            }
            self.progressBlock?(receivedSize, expectedSize)
        }) { [weak self] (image, data, error, cacheType, finished, _) in
            guard let self = self else {
                return
            }
            if let error = error as? SDWebImageError, error.code == .cancelled {
                // Ignore user cancelled
                // There are race condition when quick scroll
                // Indicator modifier disapper and trigger `WebImage.body`
                // So previous View struct call `onDisappear` and cancel the currentOperation
                return
            }
            self.image = image
            self.error = error
            self.isIncremental = !finished
            if finished {
                self.isLoading = false
                self.progress = 1
                if let image = image {
                    self.successBlock?(image, cacheType)
                } else {
                    self.failureBlock?(error ?? NSError())
                }
            }
        }
    }
    
    /// Cancel the current url loading
    public func cancel() {
        if let operation = currentOperation {
            operation.cancel()
            currentOperation = nil
            isLoading = false
        }
    }
    
    /// Prefetch the initial state of image, currently query the memory cache only
    func prefetch() {
        isFirstPrefetch = false
        // Use the options processor if provided
        let options = self.options
        var context = self.context
        if let result = manager.optionsProcessor?.processedResult(for: url, options: options, context: context) {
            context = result.context
        }
        // TODO: Remove transformer for cache calculation before SDWebImage 5.7.0, this is bug. Remove later
        let transformer = (context?[.imageTransformer] as? SDImageTransformer) ?? manager.transformer
        context?[.imageTransformer] = nil
        // TODO: before SDWebImage 5.7.0, this is the SPI. Remove later
        var key = manager.perform(Selector(("cacheKeyForURL:context:")), with: url, with: context)?.takeUnretainedValue() as? String
        if let transformer = transformer {
            key = SDTransformedKeyForKey(key, transformer.transformerKey)
        }
        // Shortcut for built-in cache
        if let imageCache = manager.imageCache as? SDImageCache {
            let image = imageCache.imageFromMemoryCache(forKey: key)
            self.image = image
            if let image = image {
                self.successBlock?(image, .memory)
            }
        } else {
            // This callback is synchronzied
            manager.imageCache.containsImage(forKey: key, cacheType: .memory) { [unowned self] (cacheType) in
                if cacheType == .memory {
                    self.manager.imageCache.queryImage(forKey: key, options: options, context: context) { [unowned self] (image, data, cacheType) in
                        self.image = image
                        if let image = image {
                            self.successBlock?(image, cacheType)
                        }
                    }
                }
            }
        }
    }
    
}

// Completion Handler
extension ImageManager {
    /// Provide the action when image load fails.
    /// - Parameters:
    ///   - action: The action to perform. The first arg is the error during loading. If `action` is `nil`, the call has no effect.
    public func setOnFailure(perform action: ((Error) -> Void)? = nil) {
        self.failureBlock = action
    }
    
    /// Provide the action when image load successes.
    /// - Parameters:
    ///   - action: The action to perform. The first arg is the loaded image, the second arg is the cache type loaded from. If `action` is `nil`, the call has no effect.
    public func setOnSuccess(perform action: ((PlatformImage, SDImageCacheType) -> Void)? = nil) {
        self.successBlock = action
    }
    
    /// Provide the action when image load progress changes.
    /// - Parameters:
    ///   - action: The action to perform. The first arg is the received size, the second arg is the total size, all in bytes. If `action` is `nil`, the call has no effect.
    public func setOnProgress(perform action: ((Int, Int) -> Void)? = nil) {
        self.progressBlock = action
    }
}

// Indicator Reportor
extension ImageManager: IndicatorReportable {}
