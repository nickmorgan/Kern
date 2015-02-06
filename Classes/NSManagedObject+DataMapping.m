
#import "NSManagedObject+Finders.h"
#import "NSManagedObject+Modifiers.h"
#import "NSManagedObject+DataMapping.h"

#import "Kern.h"

NSString * const KernIsPrimaryKey = @"__KernIsPrimaryKey";
NSString * const KernDataTypeString = @"__KernDataTypeString";
NSString * const KernDataTypeNumber = @"__KernDataTypeNumber";
NSString * const KernDataTypeBoolean = @"__KernDataTypeBoolean";
NSString * const KernDataTypeDate = @"__KernDataTypeDate";
NSString * const KernDataTypeTime = @"__KernDataTypeTime";
NSString * const KernDataTypeRelationshipBlock = @"__KernDataTypeRelationshipBlock";

NSString * const KernPrimaryKeyAttribute = @"__KernPrimaryKeyAttribute";
NSString * const KernPrimaryKeyRemoteKey = @"__KernPrimaryKeyRemoteKey";

NSUInteger kKernArrayIndexRemoteKey = 0;
NSUInteger kKernArrayIndexDataType = 1;
NSUInteger kKernArrayIndexPrimaryKeyIndicator = 2;
NSUInteger kKernArrayIndexRelationshipBlock = 2;

@implementation NSManagedObject (DataMapping)

+ (NSDictionary*)kern_mappedAttributes {
    return nil;
}

+(NSMutableDictionary*)kernPrimaryKeyStore {
	static NSMutableDictionary *sKernPrimaryKeyStore;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sKernPrimaryKeyStore = [[NSMutableDictionary alloc] init];
	});
	return sKernPrimaryKeyStore;
}

+(NSDateFormatter*)cachedDateFormatter {
	static NSDateFormatter *sCachedDateFormatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sCachedDateFormatter = [[NSDateFormatter alloc] init];
		[sCachedDateFormatter setDateFormat:@"yyyy-MM-dd"];
	});
	return sCachedDateFormatter;
}

+(NSDateFormatter*)cachedTimeFormatter {
	static NSDateFormatter *sCachedTimeFormatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
        sCachedTimeFormatter = [[NSDateFormatter alloc] init];
		[sCachedTimeFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]]; // set to utc
		[sCachedTimeFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
	});
	return sCachedTimeFormatter;
}


+ (NSMutableDictionary*)kern_primaryKeyStore {
	
	@synchronized(self.kernPrimaryKeyStore)
	{
		// create a dictionary if there's not one for this class yet
		if (self.kernPrimaryKeyStore[self.class] == nil) {
			
			// get down to just the attributes
			NSDictionary *mappedAttributes = [[[self kern_mappedAttributes] allValues] lastObject];
			for (NSString *k in mappedAttributes) {
				NSArray *obj = [mappedAttributes objectForKey:k];
				
				NSString *dataType = [obj objectAtIndex:kKernArrayIndexDataType];

				if (![dataType isEqualToString:KernDataTypeRelationshipBlock] && [obj count] > 2 && [[obj objectAtIndex:kKernArrayIndexPrimaryKeyIndicator] isEqualToString:KernIsPrimaryKey]) {
					NSString *attributeName = [[mappedAttributes allKeysForObject:obj] lastObject];
					NSString *attributeKey = [obj objectAtIndex:kKernArrayIndexRemoteKey];
					
					[self.kernPrimaryKeyStore setObject:@{KernPrimaryKeyAttribute: attributeName, KernPrimaryKeyRemoteKey: attributeKey} forKey:[self kern_entityName]];
				}
			}
			
		}
    
		return self.kernPrimaryKeyStore;
	}
}

+ (NSString*)kern_primaryKeyAttribute {
    
    return [self kern_primaryKeyStore][self.kern_entityName][KernPrimaryKeyAttribute];
}

+ (NSString*)kern_primaryKeyRemoteKey {
    return [self kern_primaryKeyStore][self.kern_entityName][KernPrimaryKeyRemoteKey];
}

+ (instancetype)findByPrimaryKey:(id)aPrimaryKeyValue {
    
    NSString *pk = [self kern_primaryKeyAttribute];
    if (pk) {
        return [[self findAllWithLimit:1 where:@"%K == %@", [self kern_primaryKeyAttribute], aPrimaryKeyValue] lastObject];
    }
    else {
        @throw [NSException exceptionWithName:@"Cannot find record" reason:@"No primary key defined" userInfo:nil];
    }
}

+ (instancetype)findOrCreateByPrimaryKey:(id)aPrimaryKeyValue {
    id obj = [self findByPrimaryKey:aPrimaryKeyValue];
    if (!obj) {
        obj = [self createEntity];
        
        [obj setValue:aPrimaryKeyValue forKey:[self kern_primaryKeyAttribute]];
    }
    return obj;
}

+ (instancetype)updateOrCreateEntityUsingRemoteDictionary:(NSDictionary *)aDictionary {
    return [self updateOrCreateEntityUsingRemoteDictionary:aDictionary andPerformBlockOnEntity:nil];
}

+ (instancetype)updateOrCreateEntityUsingRemoteDictionary:(NSDictionary *)aDictionary andPerformBlockOnEntity:(void (^)(id))entityBlock {
    
    NSDictionary *objAttributes = [[aDictionary allValues] lastObject];
    
    id pkValue = [objAttributes valueForKey:[self kern_primaryKeyRemoteKey]];

    // need to have a primary key to create or update
    if (![[objAttributes allKeys] containsObject:[self kern_primaryKeyRemoteKey]]) {
        @throw [NSException exceptionWithName:@"Can't locate primary key" reason:@"Primary key not provided in remote dictionary" userInfo:nil];
    }

    NSManagedObject *obj = [self findOrCreateByPrimaryKey:pkValue];
    
    NSDictionary *mappedAttributes = [[[self kern_mappedAttributes] allValues] lastObject];
    NSMutableDictionary *convertedAttributes = [NSMutableDictionary dictionary];

    for (NSString *attributeName in [mappedAttributes allKeys]) {
        NSArray *item = [mappedAttributes objectForKey:attributeName];
        NSString *remoteKey = [item objectAtIndex:kKernArrayIndexRemoteKey];
        // only process key if it's in our provided set
        if ([[objAttributes allKeys] containsObject:remoteKey]) {
            NSString *dataType = [item objectAtIndex:kKernArrayIndexDataType];
            
            id aValue = [objAttributes valueForKey:remoteKey];

            if ([dataType isEqualToString:KernDataTypeRelationshipBlock]) {
                KernCoreDataRelationshipBlock blk = (KernCoreDataRelationshipBlock)[item objectAtIndex:kKernArrayIndexRelationshipBlock];
                blk(obj,aValue,attributeName,remoteKey);
            }
            else {
                if (aValue != nil && aValue != [NSNull null]) {
                    if ([dataType isEqualToString:KernDataTypeString] || [dataType isEqualToString: KernDataTypeNumber] || [dataType isEqualToString:KernDataTypeBoolean]) { //strings and numbers (booleans)
                        convertedAttributes[attributeName] = aValue;
                    }
                    else if ([dataType isEqualToString:KernDataTypeDate]) {
                        NSDate *dateValue = [[self cachedDateFormatter] dateFromString:aValue];
                        if (dateValue && ![dateValue isKindOfClass:[NSNull class]]) {
                            convertedAttributes[attributeName] = dateValue;
                        }
                    }
                    else if ([dataType isEqualToString:KernDataTypeTime]) {
                        NSDate *dateValue = [[self cachedTimeFormatter] dateFromString:aValue];
                        if (dateValue && ![dateValue isKindOfClass:[NSNull class]]) {
                            convertedAttributes[attributeName] = dateValue;
                        }
                    }
                    
                }
            }
        }
    }
    
    // set using converted attributes
    [obj updateEntity:convertedAttributes];
    if (entityBlock) {
        entityBlock(obj);
    }
    
    return obj;
}

+ (NSUInteger)updateOrCreateEntitiesUsingRemoteArray:(NSArray *)anArray {
    return [self updateOrCreateEntitiesUsingRemoteArray:anArray andPerformBlockOnEntities:nil];
}

+ (NSUInteger)updateOrCreateEntitiesUsingRemoteArray:(NSArray*)anArray andPerformBlockOnEntities:(void (^)(id))entityBlock {
    NSUInteger count = 0;
    for (NSDictionary *aDictionary in anArray) {
        [self updateOrCreateEntityUsingRemoteDictionary:aDictionary andPerformBlockOnEntity:entityBlock];
        count++;
    }
    return count;
}


+ (NSUInteger)updateOrCreateEntitiesUsingRemoteArrayMT:(NSArray *)anArray {
	NSArray* results = [self updateOrCreateEntitiesUsingRemoteArrayMT:anArray andPerformBlockOnEntities:nil];
	return [results count];
}


+ (NSArray*)updateOrCreateEntitiesUsingRemoteArrayMT:(NSArray*)anArray andPerformBlockOnEntities:(void (^)(id))entityBlock
{
	NSMutableArray *results = [NSMutableArray array];
	if([anArray count] == 0)
	{
		return results;
	}
	
	NSString *modelName = [[[self kern_mappedAttributes] allKeys] firstObject]; // mapped attributes must include model name
	NSString *pkAttribute = [self kern_primaryKeyAttribute]; // get the primary key's attribute
	NSString *pkKey = [self kern_primaryKeyRemoteKey]; // get the remote key name for the primary key
	
	NSString *keyPath = [NSString stringWithFormat:@"@unionOfObjects.%@.%@", modelName, pkKey];
	NSArray *allIDs = [anArray valueForKeyPath:keyPath];
	
	// This is temp hack for backwards compatibility
	if([allIDs count] == 0 && [modelName isEqualToString:@"tutor"])
	{
		keyPath = [NSString stringWithFormat:@"@unionOfObjects.%@s.%@", modelName, pkKey];
		allIDs = [anArray valueForKeyPath:keyPath];
	}
	
	__block NSMutableDictionary* allExistingEntitiesByPK = nil;
	// Execute on other thread if possible
	[[Kern sharedContext].parentContext performBlockAndWait:^{
		
		NSArray* allExistingEntities = [self findAllWhere:@"%K IN %@", pkAttribute, allIDs];
	
		allExistingEntitiesByPK = [NSMutableDictionary dictionaryWithCapacity:[allExistingEntities count]];
	
		for (NSManagedObject *obj in allExistingEntities)
		{
			id pkValue = [obj valueForKey:pkAttribute];
			[allExistingEntitiesByPK setObject:obj forKey:pkValue];
		}
	}];
	
	for (NSDictionary *aDictionary in anArray)
	{
		NSDictionary *objAttributes = [[aDictionary allValues] lastObject];
		id pkValue = [objAttributes valueForKey:[self kern_primaryKeyRemoteKey]];
	
		__block NSManagedObject* obj = [allExistingEntitiesByPK objectForKey:pkValue];
		if(obj == nil)
		{
			// Execute on other thread if possible
			[[Kern sharedContext].parentContext performBlockAndWait:^{
				obj = [self createEntity];
	
				[obj setValue:pkValue forKey:[self kern_primaryKeyAttribute]];
			}];
		}
		
		NSManagedObject* objForMainQueue = [self updateOrCreateEntityUsingRemoteDictionaryMT:aDictionary forObject:obj andPerformBlockOnEntity:entityBlock];
		
		[results addObject:objForMainQueue];

	}
	
	return results;
}



+ (instancetype)updateOrCreateEntityUsingRemoteDictionaryMT:(NSDictionary *)aDictionary forObject:(NSManagedObject*)obj andPerformBlockOnEntity:(void (^)(id))entityBlock {
	
	NSDictionary *objAttributes = [[aDictionary allValues] lastObject];
	
	NSDictionary *mappedAttributes = [[[self kern_mappedAttributes] allValues] lastObject];
	NSMutableDictionary *convertedAttributes = [NSMutableDictionary dictionary];
	
	for (NSString *attributeName in [mappedAttributes allKeys]) {
		NSArray *item = [mappedAttributes objectForKey:attributeName];
		NSString *remoteKey = [item objectAtIndex:kKernArrayIndexRemoteKey];
		// only process key if it's in our provided set
		if ([[objAttributes allKeys] containsObject:remoteKey]) {
			NSString *dataType = [item objectAtIndex:kKernArrayIndexDataType];
			
			id aValue = [objAttributes valueForKey:remoteKey];
			
			if ([dataType isEqualToString:KernDataTypeRelationshipBlock]) {
			[[Kern sharedContext].parentContext performBlockAndWait:^{
				KernCoreDataRelationshipBlock blk = (KernCoreDataRelationshipBlock)[item objectAtIndex:kKernArrayIndexRelationshipBlock];
				blk(obj,aValue,attributeName,remoteKey);
			}];
			}
			else {
				if (aValue != nil && aValue != [NSNull null]) {
					if ([dataType isEqualToString:KernDataTypeString] || [dataType isEqualToString: KernDataTypeNumber] || [dataType isEqualToString:KernDataTypeBoolean]) { //strings and numbers (booleans)
						convertedAttributes[attributeName] = aValue;
					}
					else if ([dataType isEqualToString:KernDataTypeDate]) {
						NSDate *dateValue = [[self cachedDateFormatter] dateFromString:aValue];
						if (dateValue && ![dateValue isKindOfClass:[NSNull class]]) {
							convertedAttributes[attributeName] = dateValue;
						}
					}
					else if ([dataType isEqualToString:KernDataTypeTime]) {
						NSDate *dateValue = [[self cachedTimeFormatter] dateFromString:aValue];
						if (dateValue && ![dateValue isKindOfClass:[NSNull class]]) {
							convertedAttributes[attributeName] = dateValue;
						}
					}
					
				}
			}
		}
	}
	
	// Execute on other thread if possible
	[[Kern sharedContext].parentContext performBlockAndWait:^{
		// set using converted attributes
		[obj updateEntity:convertedAttributes];
	}];
	
	// Switch to the main queue
	__block NSManagedObject* objForMainQueue = obj;
	[[Kern sharedContext] performBlockAndWait:^{
		
		if(objForMainQueue.managedObjectContext != [Kern sharedContext])
		{
			objForMainQueue = [[Kern sharedContext] objectWithID:obj.objectID];
		}
		
		if (entityBlock) {
			entityBlock(objForMainQueue);
		}
	
	}];
	
	return objForMainQueue;
}



@end
