"""Activate the managed built-in administrator after password injection."""
import datetime
import hmac
import json
import os

import win32net
from oslo_log import log as logging
from cloudbaseinit import conf
from cloudbaseinit.osutils import factory
from cloudbaseinit.plugins.common import base, constants

LOG = logging.getLogger(__name__)
CONF = conf.CONF
PLUGIN_VERSION = "1.2"


class EnableManagedAdministratorPlugin(base.BasePlugin):
    def execute(self, service, shared_data):
        username = shared_data.get(constants.SHARED_DATA_USERNAME, CONF.username)
        utils = factory.get_os_utils()
        if not utils.user_exists(username) or not utils.is_builtin_admin(username):
            LOG.warning("Managed administrator activation skipped for non-builtin target %s", username)
            return base.PLUGIN_EXECUTION_DONE, False

        password = shared_data.get(constants.SHARED_DATA_PASSWORD)
        expected = service.get_admin_password() if CONF.inject_user_password else None
        if not password or not expected or not hmac.compare_digest(password, expected):
            raise RuntimeError("Managed administrator requires successful metadata password injection")

        root = os.path.join(os.environ["ProgramFiles"], "Cloudbase Solutions", "Cloudbase-Init")
        policy_path = os.path.join(root, "conf", "managed-admin-policy.json")
        with open(policy_path, encoding="utf-8-sig") as stream:
            policy = json.load(stream)

        original_flags = win32net.NetUserGetInfo(None, username, 1)["flags"]
        token = None
        try:
            utils.set_user_info(username, disabled=False)
            info = win32net.NetUserGetInfo(None, username, 4)
            info["password_expired"] = 0
            win32net.NetUserSetInfo(None, username, 4, info)
            token = utils.create_user_logon_session(username, password, True)
        except Exception:
            # Preserve the prior activation state if authentication failed.
            win32net.NetUserSetInfo(None, username, 1008, {"flags": original_flags})
            raise
        finally:
            if token is not None:
                utils.close_user_logon_session(token)

        extra_disabled = False
        if policy.get("disable_extra_admin", False) and utils.user_exists("Admin"):
            if not utils.is_builtin_admin("Admin") and username.lower() != "admin":
                utils.set_user_info("Admin", disabled=True)
                extra_disabled = True

        final = win32net.NetUserGetInfo(None, username, 4)
        proof = {
            "PluginVersion": PLUGIN_VERSION,
            "Username": username,
            "SID": utils.get_user_sid(username),
            "Enabled": not bool(final["flags"] & 2),
            "PasswordExpired": bool(final["password_expired"]),
            "InjectedPasswordAuthenticated": True,
            "ExtraAdminDisabled": extra_disabled,
            "CompletedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        proof_dir = os.path.join(os.environ["ProgramData"], "Cloudbase-Init")
        os.makedirs(proof_dir, exist_ok=True)
        with open(os.path.join(proof_dir, "managed-admin-activation.json"), "w", encoding="utf-8") as stream:
            json.dump(proof, stream, indent=2)
        LOG.info("Managed administrator %s enabled; injected password authenticated; extra Admin disabled: %s", username, extra_disabled)
        return base.PLUGIN_EXECUTION_DONE, False
