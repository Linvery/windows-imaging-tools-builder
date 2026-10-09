"""Add the managed administrator plugin after the installed password plugin."""
import argparse
import ast
import configparser
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('default_module')
p.add_argument('config')
p.add_argument('proof')
args = p.parse_args()
config_path = Path(args.config)
text = config_path.read_text(encoding='utf-8-sig')
parser = configparser.RawConfigParser()
parser.read_string(text)
plugins = parser.defaults().get('plugins')
if plugins:
    plugins = [part.strip() for part in plugins.split(',') if part.strip()]
else:
    tree = ast.parse(Path(args.default_module).read_text(encoding='utf-8-sig'))
    plugins = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'ListOpt' and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == 'plugins':
            plugins = ast.literal_eval(next(k.value for k in node.keywords if k.arg == 'default'))
            break
if not plugins:
    raise RuntimeError('Installed plugin order could not be determined')
managed = 'cloudbaseinit.plugins.common.managedadmin.EnableManagedAdministratorPlugin'
plugins = [value for value in plugins if value != managed]
password = 'cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin'
if password not in plugins:
    raise RuntimeError('Password injection plugin is not configured')
plugins.insert(plugins.index(password) + 1, managed)
lines = text.splitlines()
section = ''
result = []
inserted = False
for line in lines:
    if line.strip().startswith('['):
        section = line.strip().lower()
        result.append(line)
        if section == '[default]':
            result.append('plugins=' + ','.join(plugins))
            inserted = True
    elif section == '[default]' and line.strip().lower().startswith('plugins='):
        continue
    else:
        result.append(line)
if not inserted:
    raise RuntimeError('DEFAULT config section is missing')
config_path.write_text('\r\n'.join(result) + '\r\n', encoding='utf-8')
Path(args.proof).write_text(json.dumps({'Plugins': plugins, 'ManagedPluginAfterPassword': plugins.index(managed) == plugins.index(password) + 1}, indent=2), encoding='utf-8')
print('Installed plugin order preserved; managed administrator follows password injection.')
