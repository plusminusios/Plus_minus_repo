// FaceIDFor6s — Prefs/RootListController.m
// Панель настроек в приложении Настройки

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#define kPrefPath @"/var/mobile/Library/Preferences/com.yourname.faceidfor6s.plist"

@interface FIDRootListController : PSListController
@end

@implementation FIDRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath] ?: [NSMutableDictionary new];
    d[specifier.properties[@"key"]] = value;
    [d writeToFile:kPrefPath atomically:YES];

    // Уведомляем твик о смене настроек
    notify_post("com.yourname.faceidfor6s/reload");
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    id val = d[specifier.properties[@"key"]];
    if (!val) val = specifier.properties[@"default"];
    return val;
}

@end
