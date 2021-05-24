#ifndef Simplified_TPPLOG_h
#define Simplified_TPPLOG_h

#define TPPLOG(s) \
  [Log log:[NSString stringWithFormat:@"%@: %@", \
    [NSString stringWithCString:__FUNCTION__ encoding:NSUTF8StringEncoding], s]];

#define TPPLOG_F(s, ...) \
  [Log log:[NSString stringWithFormat:@"%@: %@", \
    [NSString stringWithCString:__FUNCTION__ encoding:NSUTF8StringEncoding], \
    [NSString stringWithFormat:s, __VA_ARGS__]]];

#endif
