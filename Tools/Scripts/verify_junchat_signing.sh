#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  verify_junchat_signing.sh development <Junchat.app|Junchat.xcarchive|Junchat.ipa>
  verify_junchat_signing.sh canary <Junchat.app|Junchat.xcarchive>
  verify_junchat_signing.sh appstore <Junchat.ipa>

Checks the signed entitlements so local/debug builds stay on development APNs,
canary builds stay isolated, and upload builds stay on production APNs.
EOF
}

if [[ $# -ne 2 ]]; then
    usage
    exit 2
fi

mode="$1"
artifact="$2"
team_id="W834S4TA7S"
bundle_id="com.heyujk.junchat"
associated_domain="junchat.yyzs120.cn"
tmp_dir=""

cleanup() {
    if [[ -n "$tmp_dir" ]]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

ok() {
    printf 'ok - %s\n' "$1"
}

resolve_app_path() {
    local path="$1"
    
    case "$path" in
        *.ipa)
            tmp_dir="$(mktemp -d)"
            unzip -q "$path" -d "$tmp_dir"
            printf '%s/Payload/Junchat.app' "$tmp_dir"
            ;;
        *.xcarchive)
            printf '%s/Products/Applications/Junchat.app' "$path"
            ;;
        *.app)
            printf '%s' "$path"
            ;;
        *)
            fail "unsupported artifact type: $path"
            ;;
    esac
}

entitlements_file() {
    local bundle_path="$1"
    local output
    
    output="$(mktemp)"
    codesign -d --entitlements :- "$bundle_path" 2>/dev/null > "$output" || fail "read entitlements for $bundle_path"
    printf '%s' "$output"
}

plist_value() {
    local plist="$1"
    local key="$2"
    
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

expect_entitlement() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    local actual
    
    actual="$(plist_value "$plist" "$key")"
    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        fail "$label expected '$expected', got '${actual:-<missing>}'"
    fi
}

expect_entitlement_absent() {
    local plist="$1"
    local key="$2"
    local label="$3"
    local actual
    
    actual="$(plist_value "$plist" "$key")"
    if [[ -z "$actual" ]]; then
        ok "$label"
    else
        fail "$label expected missing, got '$actual'"
    fi
}

expect_entitlement_array_value() {
    local plist="$1"
    local key="$2"
    local index="$3"
    local expected="$4"
    local label="$5"
    local actual

    actual="$(plist_value "$plist" "$key:$index")"
    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        fail "$label expected '$expected', got '${actual:-<missing>}'"
    fi
}

case "$mode" in
    development|debug)
        expected_aps="development"
        expected_get_task_allow="true"
        ;;
    canary)
        bundle_id="com.heyujk.junchat.canary"
        associated_domain="canary.junchat.yyzs120.cn"
        expected_aps="development"
        expected_get_task_allow="true"
        ;;
    appstore|production)
        if [[ "$artifact" != *.ipa ]]; then
            fail "appstore verification must use the exported IPA, not the development-signed archive"
        fi
        expected_aps="production"
        expected_get_task_allow="false"
        ;;
    *)
        usage
        exit 2
        ;;
esac

nse_bundle_id="${bundle_id}.nse"
share_extension_bundle_id="${bundle_id}.shareextension"
app_group_id="group.${bundle_id}"
keychain_group_id="${team_id}.${bundle_id}"

app_path="$(resolve_app_path "$artifact")"
[[ -d "$app_path" ]] || fail "missing app bundle at $app_path"

nse_path="$app_path/PlugIns/NSE.appex"
[[ -d "$nse_path" ]] || fail "missing NSE bundle at $nse_path"

share_extension_path="$app_path/PlugIns/ShareExtension.appex"
[[ -d "$share_extension_path" ]] || fail "missing ShareExtension bundle at $share_extension_path"

app_entitlements="$(entitlements_file "$app_path")"
nse_entitlements="$(entitlements_file "$nse_path")"
share_extension_entitlements="$(entitlements_file "$share_extension_path")"
trap 'cleanup; rm -f "$app_entitlements" "$nse_entitlements" "$share_extension_entitlements"' EXIT

expect_entitlement "$app_entitlements" "application-identifier" "${team_id}.${bundle_id}" "main app identifier"
expect_entitlement "$app_entitlements" "aps-environment" "$expected_aps" "main app APNs environment"
expect_entitlement "$app_entitlements" "get-task-allow" "$expected_get_task_allow" "main app get-task-allow"
expect_entitlement_array_value "$app_entitlements" "com.apple.security.application-groups" 0 "$app_group_id" "main app group"
expect_entitlement_array_value "$app_entitlements" "keychain-access-groups" 0 "$keychain_group_id" "main app keychain group"
expect_entitlement_array_value "$app_entitlements" "com.apple.developer.associated-domains" 0 "applinks:${associated_domain}" "main app applinks domain"
expect_entitlement_array_value "$app_entitlements" "com.apple.developer.associated-domains" 2 "webcredentials:${associated_domain}" "main app web credentials domain"
expect_entitlement_absent "$app_entitlements" "com.apple.developer.usernotifications.filtering" "main app has no unapproved notification filtering entitlement"

expect_entitlement "$nse_entitlements" "application-identifier" "${team_id}.${nse_bundle_id}" "NSE identifier"
expect_entitlement "$nse_entitlements" "get-task-allow" "$expected_get_task_allow" "NSE get-task-allow"
expect_entitlement_array_value "$nse_entitlements" "com.apple.security.application-groups" 0 "$app_group_id" "NSE app group"
expect_entitlement_array_value "$nse_entitlements" "keychain-access-groups" 0 "$keychain_group_id" "NSE keychain group"
expect_entitlement_absent "$nse_entitlements" "com.apple.developer.usernotifications.filtering" "NSE has no unapproved notification filtering entitlement"

expect_entitlement "$share_extension_entitlements" "application-identifier" "${team_id}.${share_extension_bundle_id}" "ShareExtension identifier"
expect_entitlement "$share_extension_entitlements" "get-task-allow" "$expected_get_task_allow" "ShareExtension get-task-allow"
expect_entitlement_array_value "$share_extension_entitlements" "com.apple.security.application-groups" 0 "$app_group_id" "ShareExtension app group"
expect_entitlement_array_value "$share_extension_entitlements" "keychain-access-groups" 0 "$keychain_group_id" "ShareExtension keychain group"

printf '\nJunchat signing checks passed for %s.\n' "$mode"
