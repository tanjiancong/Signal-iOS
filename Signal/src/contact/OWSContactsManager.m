//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "OWSContactsManager.h"
#import "ContactsUpdater.h"
#import "Environment.h"
#import "Util.h"

#define ADDRESSBOOK_QUEUE dispatch_get_main_queue()

typedef BOOL (^ContactSearchBlock)(id, NSUInteger, BOOL *);

NSString *const OWSContactsManagerSignalRecipientsDidChangeNotification =
    @"OWSContactsManagerSignalRecipientsDidChangeNotification";

@interface OWSContactsManager ()

@property id addressBookReference;
@property TOCFuture *futureAddressBook;
@property ObservableValueController *observableContactsController;
@property TOCCancelTokenSource *life;
@property(atomic, copy) NSDictionary *latestContactsById;

@end

@implementation OWSContactsManager

- (void)dealloc {
    [_life cancel];
}

- (id)init {
    self = [super init];
    if (!self) {
        return self;
    }

    _life = [TOCCancelTokenSource new];
    _observableContactsController = [ObservableValueController observableValueControllerWithInitialValue:nil];
    _latestContactsById = @{};
    _avatarCache = [NSCache new];

    return self;
}

- (void)doAfterEnvironmentInitSetup {
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(9, 0)) {
        self.contactStore = [[CNContactStore alloc] init];
        [self.contactStore requestAccessForEntityType:CNEntityTypeContacts
                                    completionHandler:^(BOOL granted, NSError *_Nullable error) {
                                      if (!granted) {
                                          // We're still using the old addressbook API.
                                          // User warned if permission not granted in that setup.
                                      }
                                    }];
    }

    [self setupAddressBook];

    [self.observableContactsController watchLatestValueOnArbitraryThread:^(NSArray *latestContacts) {
      @synchronized(self) {
          [self setupLatestContacts:latestContacts];
      }
    }
                                                     untilCancelled:_life.token];
}

- (void)verifyABPermission {
    if (!self.addressBookReference) {
        [self setupAddressBook];
    }
}

#pragma mark - Address Book callbacks

void onAddressBookChanged(ABAddressBookRef notifyAddressBook, CFDictionaryRef info, void *context);
void onAddressBookChanged(ABAddressBookRef notifyAddressBook, CFDictionaryRef info, void *context) {
    OWSContactsManager *contactsManager = (__bridge OWSContactsManager *)context;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [contactsManager handleAddressBookChanged];
    });
}

- (void)handleAddressBookChanged
{
    [self pullLatestAddressBook];
    [self intersectContacts];
    [self.avatarCache removeAllObjects];
}

#pragma mark - Setup

- (void)setupAddressBook {
    dispatch_async(ADDRESSBOOK_QUEUE, ^{
      [[OWSContactsManager asyncGetAddressBook] thenDo:^(id addressBook) {
        self.addressBookReference = addressBook;
        ABAddressBookRef cfAddressBook = (__bridge ABAddressBookRef)addressBook;
        ABAddressBookRegisterExternalChangeCallback(cfAddressBook, onAddressBookChanged, (__bridge void *)self);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self handleAddressBookChanged];
        });
      }];
    });
}

- (void)intersectContacts {
    [[ContactsUpdater sharedUpdater] updateSignalContactIntersectionWithABContacts:self.allContacts
                                                                           success:^{
                                                                               DDLogInfo(@"%@ Successfully intersected contacts.", self.tag);
                                                                               [self fireSignalRecipientsDidChange];
                                                                           }
                                                                           failure:^(NSError *error) {
                                                                               DDLogWarn(@"%@ Failed to intersect contacts with error: %@. Rescheduling", self.tag, error);
                                                                               
                                                                               [NSTimer scheduledTimerWithTimeInterval:60
                                                                                                                target:self
                                                                                                              selector:@selector(intersectContacts)
                                                                                                              userInfo:nil
                                                                                                               repeats:NO];
                                                                           }];
}

- (void)fireSignalRecipientsDidChange
{
    AssertIsOnMainThread();

    [[NSNotificationCenter defaultCenter] postNotificationName:OWSContactsManagerSignalRecipientsDidChangeNotification
                                                        object:nil];
}

- (void)pullLatestAddressBook {
    CFErrorRef creationError        = nil;
    ABAddressBookRef addressBookRef = ABAddressBookCreateWithOptions(NULL, &creationError);
    checkOperationDescribe(nil == creationError, [((__bridge NSError *)creationError)localizedDescription]);
    ABAddressBookRequestAccessWithCompletion(addressBookRef, ^(bool granted, CFErrorRef error) {
      if (!granted) {
          [OWSContactsManager blockingContactDialog];
      }
    });
    [self.observableContactsController updateValue:[self getContactsFromAddressBook:addressBookRef]];
}

- (void)setupLatestContacts:(NSArray *)contacts {
    if (contacts) {
        self.latestContactsById = [OWSContactsManager keyContactsById:contacts];
    }
}

+ (void)blockingContactDialog {
    switch (ABAddressBookGetAuthorizationStatus()) {
        case kABAuthorizationStatusRestricted: {
            UIAlertController *controller =
                [UIAlertController alertControllerWithTitle:NSLocalizedString(@"AB_PERMISSION_MISSING_TITLE", nil)
                                                    message:NSLocalizedString(@"ADDRESSBOOK_RESTRICTED_ALERT_BODY", nil)
                                             preferredStyle:UIAlertControllerStyleAlert];

            [controller
                addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ADDRESSBOOK_RESTRICTED_ALERT_BUTTON", nil)
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
                                                     [DDLog flushLog];
                                                     exit(0);
                                                 }]];

            [[UIApplication sharedApplication]
                    .keyWindow.rootViewController presentViewController:controller
                                                               animated:YES
                                                             completion:nil];

            break;
        }
        case kABAuthorizationStatusDenied: {
            UIAlertController *controller =
                [UIAlertController alertControllerWithTitle:NSLocalizedString(@"AB_PERMISSION_MISSING_TITLE", nil)
                                                    message:NSLocalizedString(@"AB_PERMISSION_MISSING_BODY", nil)
                                             preferredStyle:UIAlertControllerStyleAlert];

            [controller addAction:[UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"AB_PERMISSION_MISSING_ACTION", nil)
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *action) {
                                                [[UIApplication sharedApplication]
                                                    openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                                              }]];

            [[[UIApplication sharedApplication] keyWindow]
                    .rootViewController presentViewController:controller
                                                     animated:YES
                                                   completion:nil];
            break;
        }

        case kABAuthorizationStatusNotDetermined: {
            DDLogInfo(@"AddressBook access not granted but status undetermined.");
            [[Environment getCurrent].contactsManager pullLatestAddressBook];
            break;
        }

        case kABAuthorizationStatusAuthorized: {
            DDLogInfo(@"AddressBook access not granted but status authorized.");
            break;
        }

        default:
            break;
    }
}

#pragma mark - Observables

- (ObservableValue *)getObservableContacts {
    return self.observableContactsController;
}

#pragma mark - Address Book utils

+ (TOCFuture *)asyncGetAddressBook {
    CFErrorRef creationError        = nil;
    ABAddressBookRef addressBookRef = ABAddressBookCreateWithOptions(NULL, &creationError);
    assert((addressBookRef == nil) == (creationError != nil));
    if (creationError != nil) {
        [self blockingContactDialog];
        return [TOCFuture futureWithFailure:(__bridge_transfer id)creationError];
    }

    TOCFutureSource *futureAddressBookSource = [TOCFutureSource new];

    id addressBook = (__bridge_transfer id)addressBookRef;
    ABAddressBookRequestAccessWithCompletion(addressBookRef, ^(bool granted, CFErrorRef requestAccessError) {
      if (granted && ABAddressBookGetAuthorizationStatus() == kABAuthorizationStatusAuthorized) {
          dispatch_async(ADDRESSBOOK_QUEUE, ^{
            [futureAddressBookSource trySetResult:addressBook];
          });
      } else {
          [self blockingContactDialog];
          [futureAddressBookSource trySetFailure:(__bridge id)requestAccessError];
      }
    });

    return futureAddressBookSource.future;
}

- (NSArray *)getContactsFromAddressBook:(ABAddressBookRef _Nonnull)addressBook {
    CFArrayRef allPeople = ABAddressBookCopyArrayOfAllPeople(addressBook);
    CFMutableArrayRef allPeopleMutable =
        CFArrayCreateMutableCopy(kCFAllocatorDefault, CFArrayGetCount(allPeople), allPeople);

    CFArraySortValues(allPeopleMutable,
                      CFRangeMake(0, CFArrayGetCount(allPeopleMutable)),
                      (CFComparatorFunction)ABPersonComparePeopleByName,
                      (void *)(unsigned long)ABPersonGetSortOrdering());

    NSArray *sortedPeople = (__bridge_transfer NSArray *)allPeopleMutable;

    // This predicate returns all contacts from the addressbook having at least one phone number

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id record, NSDictionary *bindings) {
      ABMultiValueRef phoneNumbers = ABRecordCopyValue((__bridge ABRecordRef)record, kABPersonPhoneProperty);
      BOOL result                  = NO;

      for (CFIndex i = 0; i < ABMultiValueGetCount(phoneNumbers); i++) {
          NSString *phoneNumber = (__bridge_transfer NSString *)ABMultiValueCopyValueAtIndex(phoneNumbers, i);
          if (phoneNumber.length > 0) {
              result = YES;
              break;
          }
      }
      CFRelease(phoneNumbers);
      return result;
    }];
    CFRelease(allPeople);
    NSArray *filteredContacts = [sortedPeople filteredArrayUsingPredicate:predicate];

    return [filteredContacts map:^id(id item) {
      return [self contactForRecord:(__bridge ABRecordRef)item];
    }];
}

#pragma mark - Contact/Phone Number util

- (Contact *)contactForRecord:(ABRecordRef)record {
    ABRecordID recordID = ABRecordGetRecordID(record);

    NSString *firstName   = (__bridge_transfer NSString *)ABRecordCopyValue(record, kABPersonFirstNameProperty);
    NSString *lastName    = (__bridge_transfer NSString *)ABRecordCopyValue(record, kABPersonLastNameProperty);
    NSArray *phoneNumbers = [self phoneNumbersForRecord:record];

    if (!firstName && !lastName) {
        NSString *companyName = (__bridge_transfer NSString *)ABRecordCopyValue(record, kABPersonOrganizationProperty);
        if (companyName) {
            firstName = companyName;
        } else if (phoneNumbers.count) {
            firstName = phoneNumbers.firstObject;
        }
    }

    //    NSString *notes = (__bridge_transfer NSString *)ABRecordCopyValue(record, kABPersonNoteProperty);
    //    NSArray *emails = [ContactsManager emailsForRecord:record];
    NSData *image = (__bridge_transfer NSData *)ABPersonCopyImageDataWithFormat(record, kABPersonImageFormatThumbnail);
    UIImage *img = [UIImage imageWithData:image];
    
    return [[Contact alloc] initWithContactWithFirstName:firstName
                                             andLastName:lastName
                                 andUserTextPhoneNumbers:phoneNumbers
                                                andImage:img
                                            andContactID:recordID];
}

- (Contact * _Nullable)latestContactForPhoneNumber:(PhoneNumber *)phoneNumber {
    NSArray *allContacts = [self allContacts];

    ContactSearchBlock searchBlock = ^BOOL(Contact *contact, NSUInteger idx, BOOL *stop) {
      for (PhoneNumber *number in contact.parsedPhoneNumbers) {
          if ([self phoneNumber:number matchesNumber:phoneNumber]) {
              *stop = YES;
              return YES;
          }
      }
      return NO;
    };

    NSUInteger contactIndex = [allContacts indexOfObjectPassingTest:searchBlock];

    if (contactIndex != NSNotFound) {
        return allContacts[contactIndex];
    } else {
        return nil;
    }
}

- (BOOL)phoneNumber:(PhoneNumber *)phoneNumber1 matchesNumber:(PhoneNumber *)phoneNumber2 {
    return [phoneNumber1.toE164 isEqualToString:phoneNumber2.toE164];
}

- (NSArray *)phoneNumbersForRecord:(ABRecordRef)record {
    ABMultiValueRef numberRefs = ABRecordCopyValue(record, kABPersonPhoneProperty);

    @try {
        NSArray *phoneNumbers = (__bridge_transfer NSArray *)ABMultiValueCopyArrayOfAllValues(numberRefs);

        if (phoneNumbers == nil)
            phoneNumbers = @[];

        NSMutableArray *numbers = [NSMutableArray array];

        for (NSUInteger i = 0; i < phoneNumbers.count; i++) {
            NSString *phoneNumber = phoneNumbers[i];
            [numbers addObject:phoneNumber];
        }

        return numbers;

    } @finally {
        if (numberRefs) {
            CFRelease(numberRefs);
        }
    }
}

+ (NSDictionary *)keyContactsById:(NSArray *)contacts {
    return [contacts keyedBy:^id(Contact *contact) {
      return @((int)contact.recordID);
    }];
}

- (NSArray<Contact *> *_Nonnull)allContacts {
    NSMutableArray *allContacts = [NSMutableArray array];

    for (NSString *key in self.latestContactsById.allKeys) {
        Contact *contact = [self.latestContactsById objectForKey:key];

        if ([contact isKindOfClass:[Contact class]]) {
            [allContacts addObject:contact];
        }
    }
    return allContacts;
}

#pragma mark - Whisper User Management

- (NSArray *)getSignalUsersFromContactsArray:(NSArray *)contacts {
    NSMutableDictionary *signalContacts = [NSMutableDictionary new];
    for (Contact *contact in contacts) {
        if ([contact isSignalContact]) {
            signalContacts[contact.textSecureIdentifiers.firstObject] = contact;
        }
    }

    return [signalContacts.allValues sortedArrayUsingComparator:[[self class] contactComparator]];
}

+ (NSComparator)contactComparator
{
    BOOL firstNameOrdering = ABPersonGetSortOrdering() == kABPersonCompositeNameFormatFirstNameFirst ? YES : NO;
    return [Contact comparatorSortingNamesByFirstThenLast:firstNameOrdering];
}

- (NSArray<Contact *> * _Nonnull)signalContacts {
    return [self getSignalUsersFromContactsArray:[self allContacts]];
}

- (NSString *)unknownContactName
{
    return NSLocalizedString(@"UNKNOWN_CONTACT_NAME",
                             @"Displayed if for some reason we can't determine a contacts phone number *or* name");
}

- (NSString * _Nonnull)displayNameForPhoneIdentifier:(NSString * _Nullable)identifier {
    if (!identifier) {
        return self.unknownContactName;
    }
    Contact *contact = [self contactForPhoneIdentifier:identifier];
    
    NSString *displayName = (contact.fullName.length > 0) ? contact.fullName : identifier;
    
    return displayName;
}

- (NSAttributedString *_Nonnull)formattedFullNameForContact:(Contact *)contact font:(UIFont *_Nonnull)font
{
    UIFont *boldFont = [UIFont ows_mediumFontWithSize:font.pointSize];

    NSDictionary<NSString *, id> *boldFontAttributes =
        @{ NSFontAttributeName : boldFont, NSForegroundColorAttributeName : [UIColor blackColor] };

    NSDictionary<NSString *, id> *normalFontAttributes =
        @{ NSFontAttributeName : font, NSForegroundColorAttributeName : [UIColor ows_darkGrayColor] };

    NSAttributedString *_Nullable firstName, *_Nullable lastName;
    if (ABPersonGetSortOrdering() == kABPersonSortByFirstName) {
        if (contact.firstName) {
            firstName = [[NSAttributedString alloc] initWithString:contact.firstName attributes:boldFontAttributes];
        }
        if (contact.lastName) {
            lastName = [[NSAttributedString alloc] initWithString:contact.lastName attributes:normalFontAttributes];
        }
    } else {
        if (contact.firstName) {
            firstName = [[NSAttributedString alloc] initWithString:contact.firstName attributes:normalFontAttributes];
        }
        if (contact.lastName) {
            lastName = [[NSAttributedString alloc] initWithString:contact.lastName attributes:boldFontAttributes];
        }
    }

    NSAttributedString *_Nullable leftName, *_Nullable rightName;
    if (ABPersonGetCompositeNameFormat() == kABPersonCompositeNameFormatFirstNameFirst) {
        leftName = firstName;
        rightName = lastName;
    } else {
        leftName = lastName;
        rightName = firstName;
    }

    NSMutableAttributedString *fullNameString = [NSMutableAttributedString new];
    if (leftName) {
        [fullNameString appendAttributedString:leftName];
    }
    if (leftName && rightName) {
        [fullNameString appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }
    if (rightName) {
        [fullNameString appendAttributedString:rightName];
    }

    return fullNameString;
}

- (Contact * _Nullable)contactForPhoneIdentifier:(NSString * _Nullable)identifier {
    if (!identifier) {
        return nil;
    }
    for (Contact *contact in self.allContacts) {
        for (PhoneNumber *phoneNumber in contact.parsedPhoneNumbers) {
            if ([phoneNumber.toE164 isEqualToString:identifier]) {
                return contact;
            }
        }
    }
    return nil;
}

- (Contact *)getOrBuildContactForPhoneIdentifier:(NSString *)identifier
{
    Contact *savedContact = [self contactForPhoneIdentifier:identifier];
    if (savedContact) {
        return savedContact;
    } else {
        return [[Contact alloc] initWithContactWithFirstName:self.unknownContactName
                                                 andLastName:nil
                                     andUserTextPhoneNumbers:@[ identifier ]
                                                    andImage:nil
                                                andContactID:0];
    }
}


- (UIImage * _Nullable)imageForPhoneIdentifier:(NSString * _Nullable)identifier {
    Contact *contact = [self contactForPhoneIdentifier:identifier];

    return contact.image;
}

#pragma mark - Logging

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end
