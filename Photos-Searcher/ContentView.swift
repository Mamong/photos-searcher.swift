//
//  LibrarySearchView.swift
//  Photos-Searcher
//
//  Created by tryao on 2023/7/8.
//

import SwiftUI
import Foundation
import Photos
import CoreML
import GRDB

struct ContentView: View {
    let logTracer = LogTracer();
    @State var tokenizer: BPETokenizer? = nil;
    @State var textEncoder: ClipTextEncoder? = nil;
    @State var imageEncoder: ClipImageEncoder? = nil;
    @State var photoFeatures: [String: [Float32]] = [:];

    @State var isInitModel: Bool = false;
    @State var isModelReady: Bool = false;
    @State var isFeaturesReady: Bool = false;
    @State var keyword: String = "";
    @State var message: String = "";
    @State var displayImages: [UIImage] = [];
    @State var displayFeatures: [Float32] = [];
    @State var isSearching = false;

    var body: some View {
        VStack {
            if !isInitModel {

                Button(action: {
                    isInitModel = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        initModels()
                        checkPhotoLibraryAuth()
                    }
                }, label: {
                    Text("Scan Photos")
                })
                        .padding(20)
                        .border(.blue, width: 2)
            } else if !isModelReady {
                Text("Scaning photos...")
            } else {
                if #available(iOS 15.0, *) {
                    HStack {
                        Text("Keyword")
                        TextField("Keyword", text: $keyword)
                    }
                    .padding(20).textInputAutocapitalization(TextInputAutocapitalization.never)
                } else {
                    HStack {
                        Text("Keyword")
                        TextField("Keyword", text: $keyword)
                    }
                    .padding(20).autocapitalization(UITextAutocapitalizationType.none)
                }
                Button(action: {
                    isSearching = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        search()
                    }
                }, label: {
                    if isSearching {
                        Text("Searching...")
                    } else {
                        Text("Search")
                    }
                })
                        .disabled(isSearching)
                Spacer()

                ScrollView {
                    ForEach(Array(displayImages.enumerated()), id: \.offset) { idx, image in
                        if !isSearching{
                            Image(uiImage: image)
                                .resizable()
                                .imageScale(.large)
                                .aspectRatio(contentMode: .fit)
                            Text("Probs: \(displayFeatures[idx])")
                        }
                    }
                }

            }
        }
        .padding().onTapGesture {
            if #available(iOS 15.0, *){
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                scene?.keyWindow?.endEditing(true)
            }else{
                UIApplication.shared.windows.first?.endEditing(true)
            }
        }
    }

    func checkPhotoLibraryAuth(){
        PHPhotoLibrary.requestAuthorization { (status) in
               switch status {
               case .authorized:
                   print("Good to proceed")
                   scanPhotos()
               case .denied, .restricted:
                   print("Not allowed")
               case .notDetermined:
                   print("Not determined yet")
               case .limited:
                   print("limited")
               @unknown default:
                   print("unknown")
               }
           }
    }

    func initModels() {
        logTracer.start()
        if (isModelReady) {
            return
        }
        logTracer.logWithTime(msg: "start init model");

        // Initialize Tokenizer
        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json") else {
            fatalError("BPE tokenizer vocabulary file is missing from bundle")
        }
        guard let mergesURL = Bundle.main.url(forResource: "merges", withExtension: "txt") else {
            fatalError("BPE tokenizer merges file is missing from bundle")
        }
        logTracer.logWithTime(msg: "init URLs");

        do {
            self.tokenizer = try BPETokenizer(mergesAt: mergesURL, vocabularyAt: vocabURL);
        } catch {
            print(error)
        }
        logTracer.logWithTime(msg: "Initialized tokenizer")

        // Initialize Image Encoder
        do {
            let config = MLModelConfiguration()
            self.imageEncoder = try ClipImageEncoder(configuration: config)
        } catch {
            print("Failed to init ImageEncoder")
            print(error)
        }
        logTracer.logWithTime(msg: "Initialized image encoder")
        print("Initialized ImageEncoder")

        DispatchQueue.global(qos: .userInitiated).async {
            // Initialize Text Encoder
            do {
                let config = MLModelConfiguration()
                self.textEncoder = try ClipTextEncoder(configuration: config)
            } catch {
                print("Failed to init TextEncoder")
                print(error)
            }
            logTracer.logWithTime(msg: "Initialized text encoder")
            print("Initialized TextEncoder")
        }

    }

    func scanPhotos() {
        let startTS = NSDate().timeIntervalSince1970

        if (isModelReady) {
            return
        }

        print("Scan photos")
        // Getting features from example photos
        var localIds: Set<String> = []

        //PHPhotoLibrary.shared().register(self)

        do {
            try dbQueue.read { db in
                let allFeatures = try! Feature.fetchAll(db)
                print("Reload from database: \(NSDate().timeIntervalSince1970 - startTS)")

                for i in 0..<allFeatures.count {
                    let f = allFeatures[i]
                    let featureData = f.feature
                    let localId = f.localId

                    let feature = try! featureData.withUnsafeBytes(){ (buffer: UnsafeRawBufferPointer) throws -> [Float32] in
                        return Array<Float32>(buffer.bindMemory(to: Float32.self))
                    }
                    localIds.insert(localId)
                    self.photoFeatures[localId] = feature;
                }
            }
        } catch {
            print(error)
        }
        print("Parse vector from database: \(NSDate().timeIntervalSince1970 - startTS)")

        var photos = [PHAsset]()
        let fetchOptions = PHFetchOptions()
        //fetchOptions.includeAssetSourceTypes = [.typeUserLibrary]
        //fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        //fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        let imageManager = PHImageManager()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isSynchronous = true
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        //查找没有缓存特征的图片
        allPhotos.enumerateObjects { asset, idx, _ in
            if self.photoFeatures[asset.localIdentifier] == nil {
                photos.append(asset)
            }else{
                localIds.remove(asset.localIdentifier)
            }
        }

        //清除已删除图的特征
        if localIds.isEmpty == false {
            localIds.forEach { id in
                self.photoFeatures.removeValue(forKey: id)
                _ = try? dbQueue.write({ db in
                    try Feature.deleteOne(db, key: ["localId":id])
                })
            }
        }

        //缓存新增图的特征
        let group = DispatchGroup()
        for (idx, photo) in photos.enumerated() {
            group.enter()
            imageManager.requestImage(for: photo, targetSize: CGSizeMake(244, 244), contentMode: PHImageContentMode.aspectFill, options: options) { image, info in
                if let image{
                    extractFeatures(asset: photo, image: image)
                    print("extractFeatures:\(idx)")
                }else{
                    print("fail extractFeatures:\(idx)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let endTS = NSDate().timeIntervalSince1970
            print("Elapsed: \(endTS - startTS)")
            isModelReady = true
        }
    }

    func get_keyword_features() -> MLMultiArray? {
        let shape1x77 = [1, 77] as [NSNumber]
        guard let multiarray1x77 = try? MLMultiArray(shape: shape1x77, dataType: .float32) else {
            return nil;
        }
        do {
            let (_, tokenIDs) = tokenizer!.tokenize(input: keyword.lowercased())
            for (idx, tokenID) in tokenIDs.enumerated() {
                let key = [0, idx] as [NSNumber]
                multiarray1x77[key] = tokenID as NSNumber
            }
            let input = ClipTextEncoderInput(text: multiarray1x77)
            let output = try self.textEncoder!.prediction(input: input)
            return output.features
        } catch {
            print("Failed to parse features of keyword")
            print(error)
        }
        return nil
    }

    func search() {
        let startTS = NSDate().timeIntervalSince1970

        if self.keyword.isEmpty {
            // TODO: return message
            return;
        }
        let features = get_keyword_features()

        let textArr = convertMultiArray(input: features!)
        var sims: [String: Float32] = [:];
//        var sims: [Float32] = [];
        for (localId, imageFeature) in photoFeatures {
            let out = cosineSimilarity(textArr, imageFeature)
            sims[localId] = out
        }
        let sortedSims = sims.sorted {
            $0.value > $1.value
        }

        displayImages.removeAll()
        displayFeatures.removeAll()

        let imageManager = PHCachingImageManager()
        let options = PHImageRequestOptions()
        //options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let group = DispatchGroup()
        for p in sortedSims.prefix(20) {
            group.enter()
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [p.key], options: nil)
            imageManager.requestImage(for: result.firstObject!, targetSize: CGSize.init(width: 1024, height: 1024), contentMode: PHImageContentMode.default, options: options) { image, info in
                if let image{
                    displayImages.append(image)
                    displayFeatures.append(p.value)
                }else{
                    //原图在iCloud中
                    //let icloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                    print("\(p.key) failed to fetch image:\(info!)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            isSearching = false;
            print("Search \(NSDate().timeIntervalSince1970 - startTS)")
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange){

    }

    func extractFeatures(asset: PHAsset, image:UIImage){
        // TODO: Use Vision package to resize and center crop image.
        let ciImage = CIImage(image: image)
        let cgImage = convertCIImageToCGImage(inputImage: ciImage!)
        do {
            let input = try ClipImageEncoderInput(imageWith: cgImage!)
            let output = try self.imageEncoder?.prediction(input: input)
            let outputFeatures = output!.features
            let featuresArray = convertMultiArray(input: outputFeatures)
            let data = featuresArray.withUnsafeBufferPointer { (pointer:UnsafeBufferPointer<Float32>) in
                return Data(buffer: pointer)
            }

            self.photoFeatures[asset.localIdentifier] = featuresArray

            try dbQueue.write { db in
                var x = Feature( feature: data,
                                 localId: asset.localIdentifier)
                try! x.insert(db)
            }
        } catch {
            print("Failed to encode image photo")
            print(error)
        }
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

