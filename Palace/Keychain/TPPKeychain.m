#import "TPPKeychain.h"

#import "Palace-Swift.h"

@implementation TPPKeychain

+ (instancetype)sharedKeychain
{
  static TPPKeychain *sharedKeychain = nil;
  
  // According to http://stackoverflow.com/questions/22082996/testing-the-keychain-osstatus-error-34018
  //  instantiating the keychain via GCD can cause errors later when trying to add to the keychain
  if (sharedKeychain == nil) {
    sharedKeychain = [[self alloc] init];
    if(!sharedKeychain) {
      TPPLOG(@"Failed to create shared keychain.");
    }
  }
  
  return sharedKeychain;
}

- (NSMutableDictionary *const)defaultDictionary
{
  NSMutableDictionary *const dictionary = [NSMutableDictionary dictionary];
  dictionary[(__bridge __strong id) kSecClass] = (__bridge id) kSecClassGenericPassword;
  return dictionary;
}

- (id)objectForKey:(NSString *const)key
{
  NSData *const keyData = [NSKeyedArchiver archivedDataWithRootObject:key];
  
  NSMutableDictionary *const dictionary = [self defaultDictionary];
  dictionary[(__bridge __strong id) kSecAttrAccount] = keyData;
  dictionary[(__bridge __strong id) kSecMatchLimit] = (__bridge id) kSecMatchLimitOne;
  dictionary[(__bridge __strong id) kSecReturnData] = (__bridge id) kCFBooleanTrue;
  
  CFTypeRef resultRef = NULL;
  SecItemCopyMatching((__bridge CFDictionaryRef) dictionary, &resultRef);
  
  NSData *const result = (__bridge_transfer NSData *) resultRef;
  if(!result) return nil;
  
  return [NSKeyedUnarchiver unarchiveObjectWithData:result];
}

- (void)setObject:(id)value forKey:(NSString *)key
{
  NSData *const keyData = [NSKeyedArchiver archivedDataWithRootObject:key];
  NSData *const valueData = [NSKeyedArchiver archivedDataWithRootObject:value];
  
  NSMutableDictionary *const queryDictionary = [self defaultDictionary];
  queryDictionary[(__bridge __strong id) kSecAttrAccount] = keyData;

  OSStatus status;
  if([self objectForKey:key]) {
    NSMutableDictionary *const updateDictionary = [NSMutableDictionary dictionary];
    updateDictionary[(__bridge __strong id) kSecValueData] = valueData;
    updateDictionary[(__bridge __strong id) kSecAttrAccessible] = (__bridge id _Nullable)(kSecAttrAccessibleAfterFirstUnlock);
    status = SecItemUpdate((__bridge CFDictionaryRef) queryDictionary,
                           (__bridge CFDictionaryRef) updateDictionary);
    if (status != noErr) {
      TPPLOG_F(@"Failed to UPDATE secure values to keychain. This is a known issue when running from the debugger. Error: %d", (int)status);
    }
  } else {
    NSMutableDictionary *const newItemDictionary = queryDictionary.mutableCopy;
    newItemDictionary[(__bridge __strong id) kSecValueData] = valueData;
    newItemDictionary[(__bridge __strong id) kSecAttrAccessible] = (__bridge id _Nullable)(kSecAttrAccessibleAfterFirstUnlock);
    status = SecItemAdd((__bridge CFDictionaryRef) newItemDictionary, NULL);
    if (status != noErr) {
      TPPLOG_F(@"Failed to ADD secure values to keychain. This is a known issue when running from the debugger. Error: %d", (int)status);
    }
  }
}

- (void)removeObjectForKey:(NSString *const)key
{
  NSData *const keyData = [NSKeyedArchiver archivedDataWithRootObject:key];
  
  NSMutableDictionary *const dictionary = [self defaultDictionary];
  dictionary[(__bridge __strong id) kSecAttrAccount] = keyData;
  
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef) dictionary);
  if (status != noErr && status != errSecItemNotFound) {
    TPPLOG_F(@"Failed to REMOVE object from keychain. error: %d", (int)status);
  }
}

@end
