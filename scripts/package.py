"""Distribution des sources sans base de données, jetons, caches ni environnement virtuel."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
output = root / 'dist' / 'atelier-pxe-0.2.0.zip'
output.parent.mkdir(exist_ok=True)
files = [root / name for name in ('.gitignore','.editorconfig','AGENTS.md','CLAUDE.md','.env.example','README.md','requirements.txt','requirements-dev.txt','requirements-browser.txt','constraints.txt')]
for directory in ('app','scripts','docs','tests'):
    files.extend(p for p in (root / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts and not p.is_symlink())
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(set(files)):
        archive.write(path, Path('atelier-pxe') / path.relative_to(root))
print(output)
