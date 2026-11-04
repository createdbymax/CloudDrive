"""Shared validation for update metadata. No private keys are read by the packager."""
import base64
import json
from pathlib import Path
from urllib.parse import urlparse


def update_metadata(env):
    feed = env.get('CLOUDDRIVE_SPARKLE_FEED_URL', '')
    key = env.get('CLOUDDRIVE_SPARKLE_PUBLIC_KEY', '')
    if not feed and not key and env.get('CLOUDDRIVE_RELEASE') != '1':
        return {'SUEnableAutomaticChecks': False, 'SUAllowsAutomaticUpdates': False,
                'SUAutomaticallyUpdate': False}
    parsed = urlparse(feed)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query:
        raise ValueError('Set CLOUDDRIVE_SPARKLE_FEED_URL to a public HTTPS appcast URL without credentials or query parameters.')
    try:
        valid = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid = False
    if not valid:
        raise ValueError('Set CLOUDDRIVE_SPARKLE_PUBLIC_KEY to the base64 Ed25519 public key (32 bytes).')
    return {'SUFeedURL': feed, 'SUPublicEDKey': key, 'SUEnableAutomaticChecks': False,
            'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
            'SUSendProfileInfo': False}


def configured_environment(env):
    """Owner defaults are public. Forks can opt out or supply their own feed/key."""
    result = dict(env)
    if env.get('CLOUDDRIVE_DISABLE_UPDATES') == '1':
        result['CLOUDDRIVE_SPARKLE_FEED_URL'] = ''
        result['CLOUDDRIVE_SPARKLE_PUBLIC_KEY'] = ''
        return result
    if bool(env.get('CLOUDDRIVE_SPARKLE_FEED_URL')) != bool(env.get('CLOUDDRIVE_SPARKLE_PUBLIC_KEY')):
        raise ValueError('Override both CLOUDDRIVE_SPARKLE_FEED_URL and CLOUDDRIVE_SPARKLE_PUBLIC_KEY together.')
    config = json.loads((Path(__file__).resolve().parent.parent/'release-config.json').read_text())
    if not result.get('CLOUDDRIVE_SPARKLE_FEED_URL'):
        result['CLOUDDRIVE_SPARKLE_FEED_URL'] = f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml"
    if not result.get('CLOUDDRIVE_SPARKLE_PUBLIC_KEY'):
        result['CLOUDDRIVE_SPARKLE_PUBLIC_KEY'] = config['publicKey']
    return result
