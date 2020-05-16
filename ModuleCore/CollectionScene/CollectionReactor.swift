//
//  CollectionReactor.swift
//  BrokerNewsModule
//
//  Created by Alexej Nenastev on 30/03/2019.
//  Copyright © 2019 BCS. All rights reserved.
//

import RxSwift
import RxDataSources
 
public typealias TableReactor = CollectionReactor

open class AnimatableCollectionReactor<Item: IdentifiableType & Equatable> : CollectionReactor<Item> { }

open class CollectionReactor<Item>: BaseReactor, SceneReactor {
 
    public typealias Section = DataSourceSection<Item>
    public typealias DataLoaderProvider = () -> Single<[Item]>
    public typealias MoreDataLoaderProvider = (_ offset: Int) -> Single<[Item]>
    public typealias ItemSelected = (Item, IndexPath) -> Void
    
    public enum Action {
        case loadData
        case loadMore
        case selected(IndexPath)
    }
    
    public enum Mutation {
        case inProgressLoad(Bool)
        case inProgressLoadMore(Bool)
        
        case setData([Item], dataLoadedDate: Date?)
        case moreDataLoaded([Item])
        case dataLoadError(Error)
    }
    
    public struct State {
        public var inProgressFirstLoading: Bool { return inProgressLoad && firstLoading }
        public var inProgressRefreshLoading: Bool { return inProgressLoad && !firstLoading }
        public var inProgressLoad = false
        public var inProgressLoadMore = false
        
        public var firstLoading = true
        public var endOfData = false
        public var dataState: DataState = .none
        public var sections: [Section] = []
        
        /// Когда были загружены данные
        public var dataLoadDate: Date? = nil
    }
    
    var canSelectItem: Bool  { return onItemSelected != nil }
    var canLoadMore: Bool { return moreDataLoaderProvider != nil }
    
    let onItemSelected: ItemSelected?
    let dataLoaderProvider: DataLoaderProvider
    let moreDataLoaderProvider: MoreDataLoaderProvider?
    let maxCount: Int?
    public var cache: Cache<[Item]>?
    
    public init(loader: @escaping DataLoaderProvider,
                moreDataLoader: MoreDataLoaderProvider? = nil,
                onItemSelected: ItemSelected? = nil,
                maxCount: Int? = nil,
                cache: Cache<[Item]>? = nil) {
        self.dataLoaderProvider = loader
        self.moreDataLoaderProvider = moreDataLoader
        self.onItemSelected = onItemSelected
        self.maxCount = maxCount
        self.cache = cache
    }
    
    public var initialState = State()

    public func mutate(action: Action) -> Observable<Mutation> {

        switch action {
        case .loadData:
            guard currentState.inProgressLoad == false else  { break }
            loadData()
        case .loadMore:
            guard canLoadMore && currentState.inProgressLoadMore == false && currentState.endOfData == false else { break }
            loadMore()
        case let .selected(indexPath):
            guard canSelectItem else { break }
            let item = currentState.sections[indexPath.section].items[indexPath.row]
            onItemSelected?(item, indexPath)
        }

        return .empty()
    }

    public func reduce(state: State, mutation: Mutation) -> State {
        var state = state

        switch mutation {
        case let .inProgressLoad(value):
            state.inProgressLoad = value

        case let .inProgressLoadMore(value):
            state.inProgressLoadMore = value
 
        case let .setData(items, dataLoadDate):
            state.sections = [Section(items)]
            state.endOfData = false
            state.firstLoading = false
            state.dataState = items.count > 0 ? .hasData : .dataIsEmpty
            state.dataLoadDate = dataLoadDate
            
        case let .moreDataLoaded(items):
            state.sections[0].addItems(items: items)
            state.endOfData = items.isEmpty
            state.firstLoading = false
            
        case let .dataLoadError(error):
            state.dataState = .error(error)
        }

        return state
    }
}

fileprivate extension CollectionReactor {
    
    func loadData() {
        if let cache = cache, currentState.firstLoading == true, cache.state != .noCachedData {
            
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = cache.pull(), data.isEmpty == false else { self.reloadData(); return }
                self.make(.setData(data, dataLoadedDate: cache.pushDate))
                if cache.state == .hasExpiredData {
                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .milliseconds(200)) {
                        self.reloadData()
                    }
                }
            }
        } else {
            reloadData()
        }
    }
    
    func reloadData() {
        interact(dataLoaderProvider(),
                 complete: CollectionReactor<Item>.dataReloaded,
                 error: CollectionReactor<Item>.loadingFailed,
                 inProgress: Mutation.inProgressLoad)
    }
    
    func dataReloaded(items: [Item]) {
        var items = items
        if let maxCount = maxCount {
            items = Array(items.prefix(maxCount))
        }
        DispatchQueue.global(qos: .background).async {
            self.cache?.push(data: items)
        }
        make(.setData(items, dataLoadedDate: Date()))
    }
    
    func loadMore() {
        guard let moreLoader = moreDataLoaderProvider,
              let offset = currentState.sections.first?.items.count  else { return }
        
        interact(moreLoader(offset),
                 complete: CollectionReactor<Item>.loadedMore,
                 error: CollectionReactor<Item>.loadingFailed,
                 inProgress: Mutation.inProgressLoadMore)
    }
    
    func loadedMore(items: [Item]) {
        make(.moreDataLoaded(items))
    }
    
    func loadingFailed(_ error: Error = InterruptedError()) {
        make(.dataLoadError(error))
                print("loadingFailed error = \(error)")
    }
}
