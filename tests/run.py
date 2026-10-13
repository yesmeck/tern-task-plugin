"""Run session lifecycle regression tests: python3 tests/run.py /path/to/luau."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'window.luau').read_text()
exports = '''
return { open = open_task_session, tasks = open_tasks, delete = delete_task,
    migrate = migrate_tab_tasks, names = apply_session_names, action = task_action,
    stats = stats, prs = prs }
'''
harness = (root / 'tests/sessions.luau').read_text()
harness = harness.replace('-- INSERT PLUGIN', 'local plugin = (function()\n' + source + exports + '\nend)()')
with tempfile.TemporaryDirectory(prefix='tern-task-tests-') as folder:
    script = Path(folder) / 'sessions.luau'
    script.write_text(harness)
    subprocess.run([sys.argv[1] if len(sys.argv) > 1 else 'luau', str(script)], check=True)
