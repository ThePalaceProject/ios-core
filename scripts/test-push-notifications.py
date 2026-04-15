#!/usr/bin/env python3
"""
Palace Push Notification Test Tool

Sends FCM test notifications to a Palace iOS device for NT1-NT3 regression testing.

Setup (one-time):
  1. Go to Firebase Console → Project Settings → Service Accounts
  2. Click "Generate new private key" → save as ~/.palace/firebase-service-account.json
  3. pip3 install google-auth requests

Usage:
  # Capture FCM token from connected device logs (launch app first)
  ./scripts/test-push-notifications.py capture-token

  # Send test notifications (token auto-captured or pass --token)
  ./scripts/test-push-notifications.py hold-available
  ./scripts/test-push-notifications.py loan-expiry
  ./scripts/test-push-notifications.py all

  # With explicit token
  ./scripts/test-push-notifications.py hold-available --token <FCM_TOKEN>

  # Custom service account path
  ./scripts/test-push-notifications.py all --service-account /path/to/key.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import requests
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip3 install google-auth requests")
    sys.exit(1)

# Firebase project config (from GoogleService-Info.plist)
PROJECT_ID = "the-palace-project"
FCM_V1_URL = f"https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send"
SCOPES = ["https://www.googleapis.com/auth/firebase.messaging"]

# Default paths
DEFAULT_SA_PATHS = [
    Path.home() / ".palace" / "firebase-service-account.json",
    Path.home() / ".config" / "palace" / "firebase-service-account.json",
]

TOKEN_MARKER = "[FCM_TOKEN_REGISTERED]"
TOKEN_CACHE = Path.home() / ".palace" / "fcm-token-cache.json"


def find_service_account(explicit_path=None):
    """Locate the Firebase service account JSON file."""
    if explicit_path:
        p = Path(explicit_path)
        if p.exists():
            return p
        print(f"Error: Service account not found at {p}")
        sys.exit(1)

    for p in DEFAULT_SA_PATHS:
        if p.exists():
            return p

    print("Error: No Firebase service account key found.")
    print("Download from Firebase Console → Project Settings → Service Accounts")
    print(f"Save to: {DEFAULT_SA_PATHS[0]}")
    sys.exit(1)


def get_access_token(sa_path):
    """Get an OAuth2 access token for FCM v1 API."""
    credentials = service_account.Credentials.from_service_account_file(
        str(sa_path), scopes=SCOPES
    )
    credentials.refresh(Request())
    return credentials.token


def capture_token_from_logs(timeout=15):
    """Stream device logs and capture the FCM token."""
    print(f"Streaming device logs for {timeout}s — looking for FCM token...")
    print("(Make sure the Palace app is running on the device)\n")

    # Try physical device first via devicectl
    proc = subprocess.Popen(
        [
            "xcrun", "devicectl", "device", "process", "log", "stream",
            "--style", "compact",
            "--predicate", 'process == "Palace" AND composedMessage CONTAINS "FCM_TOKEN_REGISTERED"',
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    start = time.time()
    token = None

    try:
        while time.time() - start < timeout:
            line = proc.stdout.readline()
            if not line:
                continue
            match = re.search(r'\[FCM_TOKEN_REGISTERED\]\s+(\S+)', line)
            if match:
                token = match.group(1)
                print(f"Captured FCM token: {token[:20]}...{token[-20:]}")
                break
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()

    if not token:
        # Fallback: try simctl for simulator
        print("No token from physical device. Trying simulator...")
        proc = subprocess.Popen(
            [
                "xcrun", "simctl", "spawn", "booted", "log", "stream",
                "--style", "compact",
                "--predicate", 'process == "Palace" AND composedMessage CONTAINS "FCM_TOKEN_REGISTERED"',
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        start = time.time()
        try:
            while time.time() - start < timeout:
                line = proc.stdout.readline()
                if not line:
                    continue
                match = re.search(r'\[FCM_TOKEN_REGISTERED\]\s+(\S+)', line)
                if match:
                    token = match.group(1)
                    print(f"Captured FCM token: {token[:20]}...{token[-20:]}")
                    break
        except KeyboardInterrupt:
            pass
        finally:
            proc.terminate()

    if token:
        cache_token(token)
    return token


def cache_token(token):
    """Cache the token locally for reuse."""
    TOKEN_CACHE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_CACHE.write_text(json.dumps({
        "token": token,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }))
    print(f"Token cached at {TOKEN_CACHE}")


def load_cached_token():
    """Load a previously cached token."""
    if TOKEN_CACHE.exists():
        data = json.loads(TOKEN_CACHE.read_text())
        print(f"Using cached token from {data.get('captured_at', 'unknown')}")
        return data["token"]
    return None


def resolve_token(args):
    """Get a token from args, cache, or live capture."""
    if args.token:
        return args.token

    cached = load_cached_token()
    if cached:
        return cached

    print("No token provided and no cache found. Attempting live capture...")
    token = capture_token_from_logs()
    if not token:
        print("\nCould not capture token automatically.")
        print("Options:")
        print("  1. Open Palace on device → Settings → Developer Settings → tap 'FCM Token' → paste here")
        print("  2. Re-run with: --token <TOKEN>")
        sys.exit(1)
    return token


def send_notification(access_token, fcm_token, title, body, data=None):
    """Send a notification via FCM v1 API."""
    message = {
        "message": {
            "token": fcm_token,
            "notification": {
                "title": title,
                "body": body,
            },
            "apns": {
                "payload": {
                    "aps": {
                        "sound": "default",
                        "badge": 1,
                    }
                }
            }
        }
    }

    if data:
        message["message"]["data"] = data

    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }

    resp = requests.post(FCM_V1_URL, headers=headers, json=message)

    if resp.status_code == 200:
        print(f"  SENT: {title}")
        return True
    else:
        print(f"  FAILED ({resp.status_code}): {resp.text}")
        return False


def test_hold_available(access_token, fcm_token):
    """NT1: Send a hold-available push notification.

    Payload matches CM backend: circulation/src/palace/manager/celery/tasks/notifications.py
    """
    print("\n--- NT1: Hold Available Notification ---")
    return send_notification(
        access_token,
        fcm_token,
        title="Your hold is available!",
        body='Your hold on "Test Book Title" is available at A1QA Test Library!',
        data={
            "event_type": "HoldAvailable",
            "library": "a1qa",
            "type": "ISBN",
            "identifier": "urn:isbn:0000000000000",
            "loans_endpoint": "https://gorgon.staging.palaceproject.io/a1qa/loans",
        },
    )


def test_loan_expiry(access_token, fcm_token):
    """NT2: Send a loan-expiry warning notification.

    Payload matches CM backend: circulation/src/palace/manager/celery/tasks/notifications.py
    """
    print("\n--- NT2: Loan Expiry Warning ---")
    return send_notification(
        access_token,
        fcm_token,
        title="Only 3 days left on your loan!",
        body='Your loan for "Test Book Title" at A1QA Test Library is expiring soon',
        data={
            "event_type": "LoanExpiry",
            "library": "a1qa",
            "type": "ISBN",
            "identifier": "urn:isbn:0000000000000",
            "loans_endpoint": "https://gorgon.staging.palaceproject.io/a1qa/loans",
            "days_to_expiry": "3",
        },
    )


def test_deeplink(access_token, fcm_token):
    """NT3: Send a notification that should deep-link to Holds tab.

    Uses HoldAvailable event_type — app should navigate to Holds tab on tap.
    """
    print("\n--- NT3: Deep-link to Holds Tab ---")
    return send_notification(
        access_token,
        fcm_token,
        title="Your hold is available!",
        body='Your hold on "Test Book Title" is available at A1QA Test Library!',
        data={
            "event_type": "HoldAvailable",
            "library": "a1qa",
            "type": "ISBN",
            "identifier": "urn:isbn:0000000000000",
            "loans_endpoint": "https://gorgon.staging.palaceproject.io/a1qa/loans",
        },
    )


def cmd_capture_token(args):
    """Capture and cache the FCM token from device logs."""
    token = capture_token_from_logs(timeout=args.timeout)
    if token:
        print(f"\nFull token:\n{token}")
    else:
        print("\nNo token captured. Ensure:")
        print("  1. Palace app is running on a connected device")
        print("  2. Push notifications are authorized")
        print("  3. The app build includes the FCM_TOKEN_REGISTERED log line")


def cmd_send(args, test_funcs):
    """Send test notifications."""
    sa_path = find_service_account(args.service_account)
    print(f"Using service account: {sa_path}")

    access_token = get_access_token(sa_path)
    fcm_token = resolve_token(args)
    print(f"Target token: {fcm_token[:20]}...{fcm_token[-20:]}")

    results = {}
    for name, func in test_funcs:
        results[name] = func(access_token, fcm_token)
        if len(test_funcs) > 1:
            time.sleep(2)  # space out notifications

    print("\n--- Results ---")
    for name, passed in results.items():
        status = "SENT" if passed else "FAILED"
        print(f"  {name}: {status}")

    if all(results.values()):
        print("\nAll notifications sent. Check the device to verify:")
        print("  - Notification appears in banner/notification center")
        print("  - Tapping navigates to Holds tab (for hold notifications)")
        print("  - App syncs book registry on receipt")
    else:
        print("\nSome notifications failed. Check Firebase project permissions.")


def main():
    parser = argparse.ArgumentParser(
        description="Palace Push Notification Test Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--token", "-t",
        help="FCM device token (auto-captured if not provided)",
    )
    parser.add_argument(
        "--service-account", "-s",
        help=f"Path to Firebase service account JSON (default: {DEFAULT_SA_PATHS[0]})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=15,
        help="Timeout in seconds for token capture (default: 15)",
    )

    subparsers = parser.add_subparsers(dest="command", help="Test command")

    subparsers.add_parser("capture-token", help="Capture FCM token from device logs")
    subparsers.add_parser("hold-available", help="NT1: Send hold-available notification")
    subparsers.add_parser("loan-expiry", help="NT2: Send loan-expiry warning")
    subparsers.add_parser("deeplink", help="NT3: Send notification with deep-link")
    subparsers.add_parser("all", help="Run all notification tests (NT1-NT3)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "capture-token":
        cmd_capture_token(args)
    elif args.command == "hold-available":
        cmd_send(args, [("NT1: Hold Available", test_hold_available)])
    elif args.command == "loan-expiry":
        cmd_send(args, [("NT2: Loan Expiry", test_loan_expiry)])
    elif args.command == "deeplink":
        cmd_send(args, [("NT3: Deep-link", test_deeplink)])
    elif args.command == "all":
        cmd_send(args, [
            ("NT1: Hold Available", test_hold_available),
            ("NT2: Loan Expiry", test_loan_expiry),
            ("NT3: Deep-link", test_deeplink),
        ])


if __name__ == "__main__":
    main()
