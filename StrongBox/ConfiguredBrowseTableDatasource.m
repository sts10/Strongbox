//
//  ConfiguredBrowseTableDatasource.m
//  Strongbox-iOS
//
//  Created by Mark on 24/04/2020.
//  Copyright © 2014-2021 Mark McGuill. All rights reserved.
//

#import "ConfiguredBrowseTableDatasource.h"
#import "NSArray+Extensions.h"
#import "BrowseTableViewCellHelper.h"
#import "AppPreferences.h"
#import "Utils.h"
#import "NSString+Extensions.h"

const NSUInteger kSectionIdxFavourites = 0;
const NSUInteger kSectionIdxNearlyExpired = 1;
const NSUInteger kSectionIdxExpired = 2;
const NSUInteger kSectionIdxLast = 3;

@interface ConfiguredBrowseTableDatasource ()

@property Model* viewModel;

@property BOOL isDisplayingRootGroup;

@property (strong, nonatomic) MutableOrderedDictionary<NSString*, NSArray<Node*>*>* a2zSections; 

@property (strong, nonatomic) NSArray *standardItemsCache;
@property (strong, nonatomic) NSArray<Node*> *favouritesItemsCache;
@property (strong, nonatomic) NSArray<Node*> *expiredItemsCache;
@property (strong, nonatomic) NSArray<Node*> *nearlyExpiredItemsCache;
@property BrowseTableViewCellHelper* cellHelper;

@property BrowseViewType viewType;
@property (nullable) NSUUID* currentGroupId;
@property (nullable) NSString* currentTag;

@property (readonly) BrowseSortField effectiveSortField;
@property (readonly) BOOL shouldShowAlphabeticIndex;
@property (readonly) BrowseSortConfiguration* sortConfiguration;
@end

@implementation ConfiguredBrowseTableDatasource

- (instancetype)initWithModel:(Model *)model
        isDisplayingRootGroup:(BOOL)isDisplayingRootGroup
                    tableView:(UITableView *)tableView
                     viewType:(BrowseViewType)viewType
               currentGroupId:(NSUUID *)currentGroupId
                   currentTag:(NSString *)currentTag {
    self = [super init];
    if (self) {
        self.viewModel = model;
        self.isDisplayingRootGroup = isDisplayingRootGroup;
        self.cellHelper = [[BrowseTableViewCellHelper alloc] initWithModel:self.viewModel tableView:tableView];
        self.viewType = viewType;
        self.currentGroupId = currentGroupId;
        self.currentTag = currentTag;
    }
    
    return self;
}

- (BOOL)supportsSlideActions {
    return YES;
}

- (NSUInteger)sections {
    if ( self.shouldShowAlphabeticIndex ) {
        return kSectionIdxLast + self.a2zSections.keys.count;
    }
    else {
        return  kSectionIdxLast + 1;
    }
}

- (nonnull UITableViewCell *)cellForRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    if ( self.viewType == kBrowseViewTypeTags && self.currentTag == nil ) {
        NSArray* dataSource = [self getDataSourceForSection:indexPath.section];
        NSString* tag = dataSource[indexPath.row];
        return [self.cellHelper getTagCell:indexPath tag:tag];
    }
    else {
        Node* node = [self getParamFromIndexPath:indexPath];
        
        BOOL showTotp = self.viewType == kBrowseViewTypeTotpList;
        
        return [self.cellHelper getBrowseCellForNode:node indexPath:indexPath showLargeTotpCell:showTotp showGroupLocation:NO];
    }
}

- (NSArray<NSString *> *)sectionIndexTitles {
    if ( self.shouldShowAlphabeticIndex ) {
        return self.a2zSections.keys;
    }
    else {
        return @[];
    }
}

- (NSInteger)sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    if ( self.shouldShowAlphabeticIndex ) {
        
        return index + kSectionIdxLast;
    }
    else {
        return index;
    }
}

- (NSUInteger)rowsForSection:(NSUInteger)section {
    if(!self.isDisplayingRootGroup && section < kSectionIdxLast) {
        return 0;
    }
    else {
        return [self getDataSourceForSection:section].count;
    }
}

- (NSString*)titleForSection:(NSUInteger)section {
    if(section == kSectionIdxFavourites && self.isDisplayingRootGroup && [self getDataSourceForSection:section].count) {
        return NSLocalizedString(@"browse_vc_section_title_pinned", @"Section Header Title for Pinned Items");
    }
    else if (section == kSectionIdxNearlyExpired && self.isDisplayingRootGroup && [self getDataSourceForSection:section].count) {
        return NSLocalizedString(@"browse_vc_section_title_nearly_expired", @"Section Header Title for Nearly Expired Items");
    }
    else if (section == kSectionIdxExpired && self.isDisplayingRootGroup && [self getDataSourceForSection:section].count) {
        return NSLocalizedString(@"browse_vc_section_title_expired", @"Section Header Title for Expired Items");
    }
    else if ( section >= kSectionIdxLast ) {
        if ( self.shouldShowAlphabeticIndex ) {
            return self.a2zSections.keys[section - kSectionIdxLast];
        }
        else if ( self.isDisplayingRootGroup ) {
            if (self.viewModel.metadata.showQuickViewFavourites ||
                self.viewModel.metadata.showQuickViewNearlyExpired ||
                self.viewModel.metadata.showQuickViewExpired) {
                NSUInteger countRows = [self getQuickViewRowCount];
                return countRows ? NSLocalizedString(@"browse_vc_section_title_standard_view", @"Standard View Sections Header") : nil;
            }
        }
    }
    
    return nil;
}



- (BOOL)isShowQuickViewSections {
    return self.viewType == kBrowseViewTypeHierarchy || self.viewType == kBrowseViewTypeList;
}

- (NSArray<Node*>*)loadFavouriteItems {
    if(!self.viewModel.metadata.showQuickViewFavourites || !self.viewModel.favourites.count || ![self isShowQuickViewSections] ) {
        return @[];
    }
    
    BOOL descending = self.sortConfiguration.descending;
    BOOL foldersSeparately = self.sortConfiguration.foldersOnTop;
    BrowseSortField sortField = self.effectiveSortField;
    
    return [self.viewModel filterAndSortForBrowse:self.viewModel.favourites.mutableCopy
                            includeKeePass1Backup:YES
                                includeRecycleBin:YES
                                   includeExpired:YES
                                    includeGroups:YES
                                  browseSortField:sortField
                                       descending:descending
                                foldersSeparately:foldersSeparately];
}

- (NSArray<Node*>*)loadNearlyExpiredItems {
    if(!self.viewModel.metadata.showQuickViewNearlyExpired || ![self isShowQuickViewSections]) {
        return @[];
    }
    
    NSArray<Node*>* ne = self.viewModel.database.nearlyExpiredEntries;
    
    BOOL descending = self.sortConfiguration.descending;
    BOOL foldersSeparately = self.sortConfiguration.foldersOnTop;
    BrowseSortField sortField = self.effectiveSortField;
    
    return [self.viewModel filterAndSortForBrowse:ne.mutableCopy
                            includeKeePass1Backup:NO
                                includeRecycleBin:NO
                                   includeExpired:NO
                                    includeGroups:YES
                                  browseSortField:sortField
                                       descending:descending
                                foldersSeparately:foldersSeparately];
}

- (NSArray<Node*>*)loadExpiredItems {
    if(!self.viewModel.metadata.showQuickViewExpired || ![self isShowQuickViewSections] ) {
        return @[];
    }
    
    NSArray<Node*>* exp = self.viewModel.database.expiredEntries;
    
    BOOL descending = self.sortConfiguration.descending;
    BOOL foldersSeparately = self.sortConfiguration.foldersOnTop;
    BrowseSortField sortField = self.effectiveSortField;






    
    return [self.viewModel filterAndSortForBrowse:exp.mutableCopy
                            includeKeePass1Backup:NO
                                includeRecycleBin:NO
                                   includeExpired:YES
                                    includeGroups:YES
                                  browseSortField:sortField
                                       descending:descending
                                foldersSeparately:foldersSeparately];
}

- (NSArray*)loadStandardItems  {
    NSArray<Node*>* ret = @[];
    
    if ( self.viewType == kBrowseViewTypeTags ) {
        NSString* tag = self.currentTag;
        
        if ( tag ) {
            ret = [self.viewModel entriesWithTag:tag];
        }
        else {
            return [self.viewModel.database.tagSet.allObjects sortedArrayUsingComparator:finderStringComparator];
        }
    }
    else {
        NSUUID* currentGroup = self.currentGroupId;
        
        Node* current = [self.viewModel.database getItemById:currentGroup];
        if (!current) {
            return ret; 
        }
        
        switch ( self.viewType ) {
            case kBrowseViewTypeHierarchy:
                ret = current.children;
                break;
            case kBrowseViewTypeList:
                ret = self.viewModel.database.allSearchableNoneExpiredEntries;
                break;
            case kBrowseViewTypeTotpList:
                ret = self.viewModel.database.totpEntries;
                break;
            case kBrowseViewTypeFavourites:
                ret = self.viewModel.favourites;
                break;
            default:
                break;
        }
    }
    
    BOOL descending = self.sortConfiguration.descending;
    BOOL foldersSeparately = self.sortConfiguration.foldersOnTop;
    BrowseSortField sortField = self.effectiveSortField;

    ret = [self.viewModel filterAndSortForBrowse:ret.mutableCopy
                           includeKeePass1Backup:self.viewModel.metadata.showKeePass1BackupGroup
                               includeRecycleBin:!self.viewModel.metadata.doNotShowRecycleBinInBrowse
                                  includeExpired:self.viewModel.metadata.showExpiredInBrowse
                                   includeGroups:YES
                                 browseSortField:sortField
                                      descending:descending
                               foldersSeparately:foldersSeparately];
        
    return ret;
}

- (NSString*)getSectionTitleFromItemTitle:(id)param {
    if ( self.viewType == kBrowseViewTypeTags && self.currentTag == nil ) {
        NSString* tag = param;
        if ( tag.length == 0 ) {
            return @"#";
        }
        
        NSString* prefix = [tag substringToIndex:1];
        
        if ( prefix.isAllDigits  ) {
            return @"#";
        }
        
        return prefix.localizedUppercaseString;
    }
    else {
        Node* obj = param;
        if ( obj.title.length == 0 ) {
            return @"#";
        }
        
        NSString* prefix = [obj.title substringToIndex:1];
        
        if ( prefix.isAllDigits  ) {
            return @"#";
        }
        
        return prefix.localizedUppercaseString;
    }
}

- (MutableOrderedDictionary<NSString*, NSArray<Node*>*>*)loadAlphabeticIndex {
    NSDictionary<NSString*, NSArray<Node*>*>* grouped = [self.standardItemsCache groupBy:^id _Nonnull(Node * _Nonnull obj) {
        return [self getSectionTitleFromItemTitle:obj];
    }];
    
    
    BOOL descending = self.sortConfiguration.descending;
    
    NSArray<NSString*>* sortedKeys = [grouped.allKeys sortedArrayUsingComparator:finderStringComparator];
    if ( descending ) {
        sortedKeys = sortedKeys.reverseObjectEnumerator.allObjects; 
    }
    
    MutableOrderedDictionary<NSString*, NSArray<Node*>*>* ret = [[MutableOrderedDictionary alloc] init];
    
    for ( NSString* key in sortedKeys ) {
        ret[key] = grouped[key];
    }
    
    return ret;
}

- (void)refresh {
    self.standardItemsCache = [self loadStandardItems];
    self.a2zSections = [self loadAlphabeticIndex];
    
    
    
    self.favouritesItemsCache = self.isDisplayingRootGroup ? [self loadFavouriteItems] : @[];
    self.nearlyExpiredItemsCache = self.isDisplayingRootGroup ? [self loadNearlyExpiredItems] : @[];
    self.expiredItemsCache = self.isDisplayingRootGroup ? [self loadExpiredItems] : @[];
}



- (NSUInteger)getQuickViewRowCount {
    return [self getDataSourceForSection:kSectionIdxFavourites].count +
    [self getDataSourceForSection:kSectionIdxNearlyExpired].count +
    [self getDataSourceForSection:kSectionIdxExpired].count;
}

- (NSArray*)getDataSourceForSection:(NSUInteger)section {
    if(section == kSectionIdxFavourites) {
        return self.favouritesItemsCache;
    }
    else if (section == kSectionIdxNearlyExpired) {
        return self.nearlyExpiredItemsCache;
    }
    else if (section == kSectionIdxExpired) {
        return self.expiredItemsCache;
    }
    else if(section >= kSectionIdxLast) {
        if ( self.shouldShowAlphabeticIndex ) {
            NSUInteger idx = section - kSectionIdxLast;
            NSString* sectionKey = self.a2zSections.keys[idx];
            return self.a2zSections[sectionKey];
        }
        else {
            return self.standardItemsCache;
        }
    }
    
    NSLog(@"EEEEEEK: WARNWARN: DataSource not found for section");
    return nil;
}

- (id)getParamFromIndexPath:(NSIndexPath*)indexPath {
    NSArray* dataSource = [self getDataSourceForSection:indexPath.section];
    
    if(!dataSource || indexPath.row >= dataSource.count) {
        NSLog(@"🔴 EEEEEK: WARNWARN - Should never happen but unknown node for indexpath: [%@]", indexPath);
        return nil;
    }
    
    return dataSource[indexPath.row];
}



- (BOOL)canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    

    return indexPath.section == kSectionIdxLast &&
        self.viewModel.database.originalFormat != kPasswordSafe &&
        self.sortConfiguration.field == kBrowseSortFieldNone &&
        self.viewType == kBrowseViewTypeHierarchy;
}



- (BrowseSortConfiguration *)sortConfiguration {
    BrowseSortConfiguration* sortConfig = [self.viewModel getSortConfigurationForViewType:self.viewType];

    return sortConfig;
}

- (BrowseSortField)effectiveSortField {
    BrowseSortField sortField = self.sortConfiguration.field;
        
    if ( self.viewType == kBrowseViewTypeHierarchy ) {
        return sortField;
    }

    if ( sortField == kBrowseSortFieldNone ) {
        return kBrowseSortFieldTitle;
    }
    
    return sortField;
}

- (BOOL)shouldShowAlphabeticIndex {
    if ( self.effectiveSortField == kBrowseSortFieldTitle ) {
        BOOL appropriate = self.standardItemsCache.count > 6 && self.a2zSections.count > 1;
        
        return appropriate && self.sortConfiguration.showAlphaIndex;
    }
    
    return NO;
}

@end
