import copy
import datetime
import unittest

from find_signing_profile import profile_matches


class SigningProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 18)
        self.profile = {
            "TeamIdentifier": ["HU27CJ3DK6"],
            "Platform": ["OSX"],
            "ExpirationDate": datetime.datetime(2027, 10, 18),
            "Entitlements": {
                "com.apple.application-identifier": "HU27CJ3DK6.com.androidwebcam.app",
                "com.apple.developer.system-extension.install": True,
            },
        }

    def test_valid_profile(self):
        self.assertTrue(profile_matches(self.profile, "HU27CJ3DK6", self.now))

    def test_certificate_name_suffix_is_not_team(self):
        self.assertFalse(profile_matches(self.profile, "FJ696ZCQ56", self.now))

    def test_missing_capability_expired_wrong_bundle_and_platform(self):
        for mutation in [
            lambda p: p["Entitlements"].pop("com.apple.developer.system-extension.install"),
            lambda p: p.update(ExpirationDate=self.now),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": "HU27CJ3DK6.com.example.other"}),
            lambda p: p.update(Platform=["iOS"]),
        ]:
            with self.subTest(mutation=mutation):
                profile = copy.deepcopy(self.profile)
                mutation(profile)
                self.assertFalse(profile_matches(profile, "HU27CJ3DK6", self.now))


if __name__ == "__main__":
    unittest.main()
