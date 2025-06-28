test_dir := "./TestApplications"

[positional-arguments]
copy-test-apps +apps:
    test -d {{test_dir}} || mkdir {{test_dir}}
    for app in "$@"; do cp -a "${app%/}" {{test_dir}}; done

test:
    swift build
    .build/debug/app-thinner --force-strip-never-used-apps --remove-unused-framework-versions {{test_dir}}

test-only-apps:
    swift build
    .build/debug/app-thinner --apps-only --force-strip-never-used-apps --remove-unused-framework-versions {{test_dir}}
