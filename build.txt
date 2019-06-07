#!/usr/bin/env python3
import os
import io
import sys
import json
import subprocess
import shutil
from pathlib import Path
from xml.dom import minidom
from contextlib import contextmanager
import urllib.request
from html.parser import HTMLParser
import urllib.parse
import tempfile
import re
import hashlib
import stat
import inspect
import operator
from collections import OrderedDict
import gzip

try:
    import yaml
    import requests
except ImportError:
    subprocess.run('curl https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py; ' + sys.executable + ' /tmp/get-pip.py --user', shell=True, check=True)
    subprocess.run(sys.executable + ' -m pip install -U pyyaml requests', shell=True, check=True)
    os.execv(sys.executable, [sys.executable] + sys.argv)


METADATA = OrderedDict([
    ('Releases', OrderedDict()),
    ('Extensions', OrderedDict())
])


@contextmanager
def pushd(new_dir):
    previous_dir = os.getcwd()
    os.chdir(new_dir)
    try:
        yield
    finally:
        os.chdir(previous_dir)


def call(*args, output=False, env=None, **kwargs):
    env = None if env is None else {**os.environ.copy(), **env}
    if output:
        return subprocess.run(args, stdout=subprocess.PIPE, universal_newlines=True, check=True, env=env, **kwargs).stdout
    else:
        subprocess.run(args, check=True, env=env, **kwargs)


def inline(text):
    return ' '.join(text.split())


def get_url_sha512(url, *, headers={}, raw=False):
    sha512 = hashlib.sha512()
    response = requests.get(url, headers={'Accept': 'application/octet-stream', **headers}, stream=raw)
    sha512.update(response.raw.data if raw else response.content)
    return {
        'url': url,
        'sha512': sha512.hexdigest()
    }


def load_lockfile(node_version):
    result = None
    script = "console.log(JSON.stringify(require('@yarnpkg/lockfile').parse(require('fs').readFileSync(process.stdin.fd, 'utf8')).object))"
    with tempfile.TemporaryDirectory() as tmp:
        call(str(Path(os.environ['NVM_DIR']) / 'nvm-exec'), 'npm', 'install', '--no-save', '@yarnpkg/lockfile', cwd=tmp, env={
            'NODE_VERSION': node_version
        })
        while True:
            path = Path((yield result))
            with path.open() as fd:
                result = json.loads(call(str(Path(os.environ['NVM_DIR']) / 'nvm-exec'), 'node', '-e', script, stdin=fd, cwd=tmp, output=True, env={
                    'NODE_VERSION': node_version
                }))


def get_yarn_recipe(version):
    url = requests.get('https://api.github.com/repos/yarnpkg/yarn/releases/latest').json()['assets'][1]['browser_download_url']

    return {
        'type': 'file',
        # **get_url_sha512(url),
        **get_url_sha512('https://github.com/yarnpkg/yarn/releases/download/v' + version + '/yarn-' + version + '.js'),
        'dest': 'bin',
        'dest-filename': 'yarn.js'
    }


def get_imagemagick_archive():
    version_pattern = re.compile(r'ImageMagick-(\d+)\.(\d+)\.(\d+)-(\d+)\.(.+)')

    def version_key(version):
        version = version_pattern.fullmatch(version[0]).groups()
        return (version[4] == 'tar.xz', *(int(number) for number in version[0:4]))

    contents = [content for content in minidom.parseString(
        requests.get('https://www.imagemagick.org/download/releases/digest.rdf').text
    ).documentElement.childNodes if content.nodeName == 'digest:Content']
    releases = [(
        content.attributes['rdf:about'].value,
        next(node.firstChild.data for node in content.childNodes if node.nodeName == 'digest:sha256')
    ) for content in contents]
    latest = max(releases, key=version_key)
    return {
        'type': 'archive',
        'url': 'https://www.imagemagick.org/download/releases/' + latest[0],
        'sha256': latest[1]
    }


def get_git_with_tag(url, tag):
    stream = io.TextIOWrapper(urllib.request.urlopen(url + '/info/refs?service=git-upload-pack'))
    refs = {}
    while True:
        line = stream.readline()
        line = line[4:]
        if line == '':
            break
        if line.startswith('#'):
            continue
        line = line.split('\0')[0]
        line = line.split(' ')
        refs[line[1].strip()] = line[0]
    return {
        'type': 'git',
        'url': url,
        'tag': tag,
        'commit': refs.get('refs/tags/' + tag + '^{}', refs.get('refs/tags/' + tag))
    }


def get_python_packages():
    packages = ['autopep8', 'pylint', 'pipenv', 'ipython', 'rope']
    # setup_requires = ['setuptools_scm', 'pytest-runner']
    setup_requires = []
    sources = []
    with tempfile.TemporaryDirectory() as tmpdir:
        subprocess.run('pip3 download --no-binary :all: -d' + tmpdir + ' ' + ' '.join(packages + setup_requires), shell=True)

        versions = [re.fullmatch(r'(.*)-(.*?)(\.zip|\.tar\.gz)', filename).groups()[:2] for filename in sorted(os.listdir(tmpdir))]

        for package, version in versions:
            subprocess.run('pip3 download --no-deps --platform any --abi none --implementation cp --python-version 37 -d ' + tmpdir + ' ' + package + '==' + version, shell=True)

        filenames = os.listdir(tmpdir)
        wheels = list(filter(lambda filename: filename.endswith('-none-any.whl'), filenames))

        for package, version in versions:
            filename = next((name for name in wheels if name.startswith(package + '-' + version + '-')), None)
            if filename is None:
                filename = next(name for name in filenames if name.startswith(package + '-' + version + '.'))

            metadata = requests.get('https://pypi.org/pypi/' + package + '/json/').json()
            entry = next(filter(lambda entry: entry['filename'] == filename, metadata['releases'][version]))
            sources.append({
                'type': 'file',
                'dest-filename': filename,
                'url': entry['url'],
                'sha256': entry['digests']['sha256']
            })
        return {
            'name': 'python_packages',
            'buildsystem': 'simple',
            'only-arches': ['x86_64'],
            'build-commands': [
                'mkdir -p /app/local',
                r'''echo -e "[easy_install]\nallow_hosts = ''\nfind_links = file://$PWD/" > ~/.pydistutils.cfg''',
                'PYTHONUSERBASE=/app/local pip3 install --user --no-index --find-links . ' + ' '.join(packages)
            ],
            'sources': sources
        }


def get_python_packages_x86_64(python_version):
    subprocess.run('curl https://storage.googleapis.com/travis-ci-language-archives/python/binaries/ubuntu/16.04/x86_64/python-' + python_version + '.tar.bz2 | sudo tar -xjf - --directory /', shell=True, check=True)

    packages = ['autopep8', 'pylint', 'pipenv', 'ipython', 'rope', 'flake8', 'yapf']
    patterns = {
        '.whl': re.compile(r'(?P<package>.*)-(?P<version>.*?)-.*?-.*?-.*?\.whl'),
        '.tar.gz': re.compile(r'(?P<package>.*)-(?P<version>.*?)\.tar\.gz'),
        '.zip': re.compile(r'(?P<package>.*)-(?P<version>.*?)\.zip')
    }
    with tempfile.TemporaryDirectory() as tmpdir:
        sources = []
        subprocess.run('. ~/virtualenv/python' + python_version + '/bin/activate; pip3 download -d' + tmpdir + ' ' + ' '.join(packages), shell=True, check=True)

        for filename in sorted(os.listdir(tmpdir)):
            for extension, pattern in patterns.items():
                if filename.endswith(extension):
                    match = pattern.fullmatch(filename)
                    package = match.group('package')
                    version = match.group('version')
                    break
            else:
                continue
            metadata = requests.get('https://pypi.org/pypi/' + package + '/json/').json()
            entry = next(entry for entry in metadata['releases'][version] if entry['filename'] == filename)
            sources.append({
                'type': 'file',
                'dest-filename': filename,
                'url': entry['url'],
                'sha256': entry['digests']['sha256']
            })

        return {
            'name': 'python_packages',
            'buildsystem': 'simple',
            'only-arches': ['x86_64'],
            'build-commands': [
                'mkdir -p /app/local',
                'PYTHONUSERBASE=/app/local pip3 install --user --no-index --find-links . ' + ' '.join(packages)
            ],
            'sources': sources
        }


def get_go_tools():
    class IgnoreErrorHandler(urllib.request.HTTPDefaultErrorHandler):
        def http_error_default(self, req, fp, code, msg, hdrs):
            if req.host == 'winterdrache.de' and code == 404:
                return fp
            else:
                super().http_error_default(req, fp, code, msg, hdrs)

    opener = urllib.request.build_opener(IgnoreErrorHandler)
    GOPATH = Path(os.environ.get('GOPATH', str(Path.home() / 'go')))
    GOPATH.mkdir(parents=True, exist_ok=True)
    environ = {**os.environ, 'GOPATH': str(GOPATH)}
    sources = []

    def get_meta_import(url):
        class ContentEncounteredException(Exception):
            def __init__(self, data):
                self.data = data

        class GoImportHTMLParser(HTMLParser):
            def handle_starttag(self, tag, attrs):
                if tag == 'meta' and next((value for key, value in attrs if key == 'name'), '') == 'go-import':
                    raise ContentEncounteredException(next((value for key, value in attrs if key == 'content')).split(' '))

        with opener.open(url + '?go-get=1') as stream:
            parser = GoImportHTMLParser()
            data = None
            try:
                parser.feed(stream.read().decode())
            except ContentEncounteredException as exception:
                data = exception.data
            return data

    def get_package_path(package):
        if package.startswith('github.com'):
            url = 'https://' + package
            path = urllib.parse.urlsplit(url).path.split('/')
            return Path('github.com') / path[1] / path[2], 'https://github.com/' + path[1] + '/' + path[2] + '.git'
        elif package.startswith('bitbucket.org'):
            raise NotImplementedError()
        elif package.startswith('launchpad.net'):
            raise NotImplementedError()
        elif package.startswith('hub.jazz.net'):
            raise NotImplementedError()
        else:
            url = 'https://' + package
            path = urllib.parse.urlsplit(url).path
            imports = get_meta_import(url)
            assert imports is not None
            if imports[1] != 'git':
                raise NotImplementedError()
            assert package.startswith(imports[0])
            if package != imports[0]:
                real_imports = get_meta_import('https://' + imports[0])
                assert real_imports is not None and real_imports[0] == imports[0]
            return imports[0], imports[2]

    def get_dependencies(package):
        path, url = get_package_path(package)
        if not (GOPATH / 'src' / path).exists():
            subprocess.run([
                'git',
                'clone',
                '--depth=1',
                url,
                str(GOPATH / 'src' / path)
            ], check=True)
            sources.append({
                'type': 'git',
                'url': url,
                'commit': subprocess.run([
                    'git', 'rev-parse', 'HEAD',
                ], stdout=subprocess.PIPE, universal_newlines=True, check=True, cwd=str(GOPATH / 'src' / path)).stdout.strip(),
                'dest': str(Path('src') / path)
            })

        output = subprocess.run([
            'go',
            'list',
            '-json',
            package
        ], stdout=subprocess.PIPE, universal_newlines=True, check=True, env=environ).stdout.strip()
        decoder = json.JSONDecoder()
        while len(output):
            info, index = decoder.raw_decode(output)
            output = output[index:].strip()
            if 'DepsErrors' in info:
                for error in info['DepsErrors']:
                    get_dependencies(error['ImportStack'][-1])

    commands = []
    for name, package in {
        'gocode': 'github.com/mdempsky/gocode',
        'gocode-gomod': 'github.com/stamblerre/gocode',
        'gopkgs': 'github.com/uudashr/gopkgs/cmd/gopkgs',
        'go-outline': 'github.com/ramya-rao-a/go-outline',
        'go-symbols': 'github.com/acroca/go-symbols',
        'guru': 'golang.org/x/tools/cmd/guru',
        'gorename': 'golang.org/x/tools/cmd/gorename',
        'gomodifytags': 'github.com/fatih/gomodifytags',
        'goplay': 'github.com/haya14busa/goplay/cmd/goplay',
        'impl': 'github.com/josharian/impl',
        'gotype-live': 'github.com/tylerb/gotype-live',
        'godef': 'github.com/rogpeppe/godef',
        'godef-gomod': 'github.com/ianthehat/godef',
        'gogetdoc': 'github.com/zmb3/gogetdoc',
        'goimports': 'golang.org/x/tools/cmd/goimports',
        'goreturns': 'github.com/sqs/goreturns',
        'goformat': 'winterdrache.de/goformat/goformat',
        'golint': 'golang.org/x/lint/golint',
        'gotests': 'github.com/cweill/gotests/...',
        'gometalinter': 'github.com/alecthomas/gometalinter',
        'megacheck': 'honnef.co/go/tools/...',
        'golangci-lint': 'github.com/golangci/golangci-lint/cmd/golangci-lint',
        'revive': 'github.com/mgechev/revive',
        'go-langserver': 'github.com/sourcegraph/go-langserver',
        'dlv': 'github.com/derekparker/delve/cmd/dlv',
        'fillstruct': 'github.com/davidrjenni/reftools/cmd/fillstruct',
    }.items():
        get_dependencies(package)
        if name.endswith('-gomod'):
            commands.append('GOPATH=$PWD go build -o /app/local/bin/' + name + ' ' + package)
        else:
            commands.append('GOPATH=$PWD go install ' + package)
    commands.append('mv bin/* /app/local/bin')

    return {
        'name': 'vscode-go',
        'buildsystem': 'simple',
        'only-arches': ['x86_64'],
        'build-options': {
            'append-path': '/usr/lib/sdk/golang/bin',
            'env': {'GOROOT': '/usr/lib/sdk/golang'}
        },
        'build-commands': sorted(commands),
        'sources': sorted(sources, key=operator.itemgetter('url'))
    }


def get_gitlab_with_tag(path, netloc='gitlab.com', scheme='https'):
    project = requests.get(urllib.parse.urlunsplit((
        scheme,
        netloc,
        '/api/v4/projects/' + urllib.parse.quote_plus(path),
        '',
        ''
    ))).json()
    tag = requests.get(urllib.parse.urlunsplit((
        scheme,
        netloc,
        '/api/v4/projects/' + urllib.parse.quote_plus(path) + '/repository/tags',
        urllib.parse.urlencode({
            'page': 1,
            'per_page': 1
        }),
        ''
    ))).json()[0]
    return {
        'type': 'git',
        'url': project['http_url_to_repo'],
        'tag': tag['name'],
        'commit': tag['commit']['id']
    }


def get_python_version(runtime_version):
    sdk_tag = next(release['name'] for release in requests.get(
        'https://gitlab.com/api/v4/projects/freedesktop-sdk%2Ffreedesktop-sdk/repository/tags'
    ).json() if release['name'].startswith('freedesktop-sdk-' + runtime_version + '.'))

    return re.match('v(\d+\.\d+\.\d+)-.*', yaml.load(requests.get(
        'https://gitlab.com/freedesktop-sdk/freedesktop-sdk/raw/' + sdk_tag + '/elements/base/python3.bst'
    ).text)['sources'][0]['ref']).groups()[0]


def parse_repo(base_recipe):
    releases = requests.get('https://vscode-update.azurewebsites.net/api/releases/stable', headers={'X-API-Version': '2'}).json()
    with tempfile.TemporaryDirectory() as tmp, pushd(tmp):
        call('git', 'clone', '--branch', releases[0]['version'], 'https://github.com/Microsoft/vscode.git', '.')
        releases = [{
            **release,
            'date': inline(call('git', 'show', '-s', '--format=%cd', '--date=iso-strict-local', release['id'], env={
                'TZ': 'UTC'
            }, output=True))
        } for release in releases if release['version'].split('.')[0] != '0']
        METADATA['Releases'] = OrderedDict([(release['version'], release['date']) for release in releases])

        product_json = json.loads(Path('product.json').read_text())
        # nodejs_version = Path('.nvmrc').read_text().strip()
        product_build_linux = yaml.load(Path('build/azure-pipelines/linux/product-build-linux.yml').read_text())
        nodejs_version = next(step['inputs']['versionSpec'] for step in product_build_linux['steps'] if step['task'] == 'NodeTool@0')
        yarn_version = next(step['inputs']['versionSpec'] for step in product_build_linux['steps'] if step['task'] == 'geeklearningio.gl-vsts-tasks-yarn.yarn-installer-task.YarnInstaller@2')

        nvm_exec = Path(os.environ['NVM_DIR']) / 'nvm-exec'
        if not nvm_exec.exists():
            nvm_exec.write_bytes(requests.get('https://github.com/creationix/nvm/raw/v0.33.6/nvm-exec').content)
            nvm_exec.chmod(nvm_exec.stat().st_mode | stat.S_IXUSR)

        subprocess.run(r'\. "$NVM_DIR/nvm.sh" --no-use; nvm install ' + nodejs_version, shell=True, check=True)

        loader = load_lockfile(nodejs_version)
        next(loader)

        re_node_version = re.compile(r'(.*)@.*?')
        packages = {}
        for lockpath in Path().glob('**/yarn.lock'):
            lockfile = loader.send(lockpath)
            for entry in lockfile:
                resolved = urllib.parse.urldefrag(lockfile[entry]['resolved'])
                name = re_node_version.match(entry).group(1)
                version = lockfile[entry]['version']
                if resolved[1] == '':
                    packages[(name, version)] = {
                        'type': 'file',
                        **get_url_sha512(resolved[0]),
                        'dest': 'yarn-mirror',
                        'dest-filename': resolved[0].split('/')[-1]
                    }
                else:
                    packages[(name, version)] = {
                        'type': 'file',
                        'url': resolved[0],
                        'sha1': resolved[1],
                        'dest': 'yarn-mirror',
                        'dest-filename': name.replace('/', '-') + '-' + version + '.tgz'
                    }

        builtInExtensions = []
        for item in json.loads(Path('build/builtInExtensions.json').read_text()):
            publisher, name = item['name'].split('.')
            version = item['version']
            url = 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/' + publisher + '/vsextensions/' + name + '/' + version + '/vspackage'

            builtInExtensions.append({
                'type': 'file',
                **get_url_sha512(url, headers={
                    'X-Market-Client-Id': 'VSCode Build',
                    'User-Agent': 'VSCode Build',
                    'X-Market-User-Id': '291C1CD0-051A-4123-9B4B-30D60EF52EE2',
                }, raw=True),
                'dest': 'builtInExtensions',
                'dest-filename': item['name'] + '.vsix'
            })

        return {
            **base_recipe,
            'app-id': product_json['darwinBundleIdentifier'],
            'branch': 'stable',
            'command': product_json['applicationName'],
            'separate-locales': False,
            'finish-args': [
                '--share=ipc',
                '--socket=x11',
                '--socket=pulseaudio',
                '--socket=ssh-auth',
                '--share=network',
                '--device=dri',
                '--filesystem=host',
                '--persist=' + product_json['dataFolderName'],
                '--talk-name=org.freedesktop.Notifications'
            ],
            'add-extensions': {
                product_json['darwinBundleIdentifier'] + '.Tools': {
                    'directory': 'local',
                    'add-ld-path': 'lib',
                    'bundle': True,
                    'autodelete': True,
                    'no-autodownload': True
                }
            },
            'sdk-extensions': [
                'org.freedesktop.Sdk.Extension.golang'
            ],
            'modules': [
                {
                    'name': 'libsecret',
                    'config-opts': [
                        '--disable-manpages',
                        '--disable-gtk-doc',
                        '--disable-static',
                        '--disable-introspection'
                    ],
                    'cleanup': [
                        '/bin',
                        '/include',
                        '/lib/pkgconfig',
                        '/share/gtk-doc',
                        '*.la'
                    ],
                    'sources': [
                        get_gitlab_with_tag('GNOME/libsecret', 'gitlab.gnome.org')
                    ]
                },
                {
                    'name': 'ImageMagick',
                    'build-options': {
                        'prefix': '/app/local'
                    },
                    'cleanup': [
                        '/local'
                    ],
                    'sources': [
                        get_imagemagick_archive()
                    ],
                    'config-opts': [
                        '--enable-static=no',
                        '--with-modules',
                        '--disable-docs',
                        '--disable-deprecated',
                        '--without-autotrace',
                        '--without-bzlib',
                        '--without-djvu',
                        '--without-dps',
                        '--without-fftw',
                        '--without-fontconfig',
                        '--without-fpx',
                        '--without-freetype',
                        '--without-gvc',
                        '--without-jbig',
                        '--without-jpeg',
                        '--without-lcms',
                        '--without-lzma',
                        '--without-magick-plus-plus',
                        '--without-openexr',
                        '--without-openjp2',
                        '--without-pango',
                        '--without-raqm',
                        '--without-tiff',
                        '--without-webp',
                        '--without-wmf',
                        '--without-x',
                        '--without-xml',
                        '--without-zlib'
                    ]
                },
                {
                    'name': 'node',
                    'build-options': {
                        'prefix': '/app/local'
                    },
                    'cleanup': [
                        '/local'
                    ],
                    'sources': [
                        {
                            'type': 'archive',
                            **get_url_sha512('https://nodejs.org/dist/v' + nodejs_version + '/node-v' + nodejs_version + '.tar.xz')
                        }
                    ],
                    'post-install': [
                        'python -m compileall /app/local/lib/node_modules/npm/node_modules/node-gyp'
                    ]
                },
                {
                    'name': 'vscode',
                    'buildsystem': 'simple',
                    'build-options': {
                        'append-path': '/app/local/bin'
                    },
                    'build-commands': [
                        'python3 build.py',
                    ],
                    'cleanup': [
                        '/local'
                    ],
                    'sources': [
                        {
                            'type': 'git',
                            'url': 'https://github.com/Microsoft/vscode.git',
                            'tag': releases[0]['version'],
                            'commit': releases[0]['id'],
                            'dest': 'vscode',
                            'disable-shallow-clone': True
                        },
                        {
                            'type': 'script',
                            'commands': [
                                'import os',
                                'import sys',
                                'import json',
                                'import subprocess',
                                'import shutil',
                                'from pathlib import Path',
                                'from xml.dom import minidom',
                                'from contextlib import contextmanager',
                                'import urllib.request',
                                'import urllib.parse',
                                'import tempfile',
                                'import re',
                                'import hashlib',
                                'import stat',
                                'from collections import OrderedDict',
                                'import gzip',
                                'METADATA = ' + repr(METADATA),
                                *inspect.getsource(build).split('\n'),
                                'build()'
                            ],
                            'dest-filename': 'build.py'
                        },
                        {
                            'type': 'file',
                            'path': product_json['darwinBundleIdentifier'] + '.json'
                        },
                        {
                            'type': 'file',
                            **get_url_sha512('https://raw.githubusercontent.com/Microsoft/vscode/b00945fc8c79f6db74b280ef53eba060ed9a1388/product.json')
                        },
                        *builtInExtensions,
                        *sorted(packages.values(), key=operator.itemgetter('url')),
                        get_yarn_recipe(yarn_version),
                        *get_electron_recipe(packages, loader.send('.yarnrc')['target']),
                        *get_ripgrep_recipe(packages, nodejs_version)
                    ]
                },
                get_python_packages_x86_64(get_python_version(base_recipe['runtime-version'])),
                get_go_tools(),
                {
                    'name': 'placeholder',
                    'buildsystem': 'simple',
                    'skip-arches': ['x86_64'],
                    'build-commands': [
                        'echo THIS DIRECTORY IS FOR x86_64 ONLY > /app/local/README'
                    ],
                    'sources': []
                }
            ]
        }


def get_electron_recipe(packages, iojs_version):
    def patch_zero(version):
        parts = version.split('.')
        parts[-1] = '0'
        return '.'.join(parts)

    electrons = []
    electron_recipe = []
    sha256sums = {}
    electrons.extend([('mksnapshot', patch_zero(package[1]), '.electron') for package in packages if package[0] == 'electron-mksnapshot'])
    electrons.extend([('chromedriver', patch_zero(package[1]), '.electron') for package in packages if package[0] == 'electron-chromedriver'])
    electrons.extend([('electron', package[1], '.electron') for package in packages if package[0] == 'electron'])
    electrons.append(('electron', iojs_version, 'gulp-electron-cache/atom/electron'))
    electrons.append(('ffmpeg', iojs_version, 'gulp-electron-cache/atom/electron'))
    for name, version, dest in electrons:
        if version not in sha256sums:
            sha256sums[version] = requests.get('https://github.com/electron/electron/releases/download/v' + version + '/SHASUMS256.txt').text
        for arch_linux, arch_node in [
            ('x86_64', 'x64'),
            ('i386', 'ia32'),
            ('arm', 'armv7l'),
            ('aarch64', 'arm64')
        ]:
            filename = name + '-v' + version + '-linux-' + arch_node + '.zip'
            electron_recipe.append({
                'type': 'file',
                'url': 'https://github.com/electron/electron/releases/download/v' + version + '/' + filename,
                'sha256': next(line.split(' ')[0] for line in sha256sums[version].split('\n') if filename in line),
                'only-arches': [arch_linux],
                'dest': dest,
                'dest-filename': filename
            })
    electron_recipe.append({
        'type': 'file',
        **get_url_sha512('https://atom.io/download/electron/v' + iojs_version + '/iojs-v' + iojs_version + '.tar.gz'),
        'dest': 'misc',
        'dest-filename': 'iojs.tar.gz'
    })
    return electron_recipe


def get_ripgrep_recipe(packages, node_version):
    package_version = next(package[1] for package in packages if package[0] == 'vscode-ripgrep')
    url = 'https://cdn.jsdelivr.net/npm/vscode-ripgrep@' + package_version + '/lib/postinstall.js'
    line = next(line for line in requests.get(url).text.split('\n') if line.startswith('const version'))
    line += '; console.log(version)'
    ripgrep_version = inline(call(str(Path(os.environ['NVM_DIR']) / 'nvm-exec'), 'node', '-e', line, output=True, env={
        'NODE_VERSION': node_version
    }))
    return [{
        'type': 'file',
        **get_url_sha512('https://github.com/roblourens/ripgrep/releases/download/' + ripgrep_version + '/ripgrep-' + ripgrep_version + '-linux-' + arch_node + '.zip'),
        'only-arches': [
            arch_linux
        ],
        'dest': 'vscode-ripgrep-cache-' + package_version
    } for arch_linux, arch_node in [
        ('x86_64', 'x64'),
        ('i386', 'ia32'),
        ('arm', 'arm'),
        ('aarch64', 'arm64')
    ]]


def get_base_recipe():
    base = yaml.load(requests.get(
        'https://raw.githubusercontent.com/flathub/org.electronjs.Electron2.BaseApp/master/org.electronjs.Electron2.BaseApp.yml'
    ).text)
    return {
        'base': base['id'],
        'base-version': base['branch'],
        # 'runtime': base['runtime'],
        'runtime': base['sdk'],
        'runtime-version': base['runtime-version'],
        'sdk': base['sdk']
    }


def generate_recipe():
    return parse_repo(get_base_recipe())


def build():
    product = json.loads(Path('vscode/product.json').read_text())
    product['nameLong'] = 'Visual Studio Code - OSS'
    product['extensionsGallery'] = json.loads(Path('product.json').read_text())['extensionsGallery']
    # From https://docs.microsoft.com/en-us/visualstudio/liveshare/reference/linux#vs-code-oss-issues
    product['extensionAllowedProposedApi'] = [
        'ms-vsliveshare.vsliveshare',
        'ms-vscode.node-debug',
        'ms-vscode.node-debug2'
    ]
    Path('vscode/product.json').write_text(json.dumps(product, sort_keys=True))

    recipe = json.loads(Path(os.environ['FLATPAK_ID'] + '.json').read_text())
    arch = ' '.join(subprocess.run(['node', '-e', 'console.log(process.arch)'], stdout=subprocess.PIPE, universal_newlines=True).stdout.split())

    sha256sums = {}
    for package in [source for source in next(
        module for module in recipe['modules'] if module['name'] == 'vscode'
    )['sources'] if source.get('dest') == '.electron']:
        version = package['dest-filename'].split('-')[1][1:]
        if version not in sha256sums:
            sha256sums[version] = {}
        sha256sums[version][package['dest-filename']] = package['sha256']
    for version in sha256sums:
        Path('.electron/SHASUMS256.txt-' + version).write_text('\n'.join(
            sha256sums[version][filename] + ' *' + filename for filename in sha256sums[version])
        )

    shutil.move('gulp-electron-cache', '/tmp')
    for cache in Path().glob('vscode-ripgrep-cache-*'):
        shutil.move(str(cache), '/tmp')
    shutil.move('builtInExtensions', '/tmp')
    shutil.move('.electron', str(Path.home()))
    shutil.move('bin/yarn.js', '/app/local/bin')
    Path('/app/local/bin/yarn.js').chmod(Path('/app/local/bin/yarn.js').stat().st_mode | stat.S_IXUSR)
    Path('/app/local/bin/yarn').symlink_to('yarn.js')
    subprocess.run(['yarn', 'config', 'set', 'yarn-offline-mirror', str(Path('yarn-mirror').resolve())], check=True)
    yarnrc = (Path.home() / '.yarnrc').read_text()
    (Path.home() / '.yarnrc').write_text(yarnrc + ''.join('--install.' + option + ' true\n' for option in [
        'offline',
        'verbose',
        'frozen-lockfile'
    ]))

    os.chdir('vscode')

    for path in Path('/tmp/builtInExtensions').glob('*.vsix'):
        path.write_bytes(gzip.decompress(path.read_bytes()))

    Path('build/lib/extensions.js').write_text(Path('build/lib/extensions.js').read_text().replace(
        "remote('', options)",
        "require('gulp').src('/tmp/builtInExtensions/' + extensionName + '.vsix')", 1)
    )
    Path('build/lib/extensions.ts').write_text(Path('build/lib/extensions.ts').read_text().replace(
        "remote('', options)",
        "require((console.log(remote), console.log(options), 'gulp')).src('/tmp/builtInExtensions/' + extensionName + '.vsix')", 1)
    )

    package_vscode_extension = json.loads(Path('extensions/vscode-colorize-tests/package.json').read_text())
    del package_vscode_extension['scripts']['postinstall']
    Path('extensions/vscode-colorize-tests/package.json').write_text(json.dumps(package_vscode_extension, sort_keys=True))

    subprocess.run(['yarn', 'install'], check=True, env={
        **os.environ,
        'npm_config_tarball': str(Path('../misc/iojs.tar.gz').resolve()),
        'CHILD_CONCURRENCY': '1'
    })

    # (Path.home() / '.yarnrc').write_text(yarnrc)

    shutil.copy('src/vs/vscode.d.ts', 'extensions/vscode-colorize-tests/node_modules/vscode')
    subprocess.run(['npm', 'run', 'gulp', '--', 'vscode-linux-' + arch + '-min'], check=True)

    os.chdir('..')
    shutil.move('VSCode-linux-' + arch, '/app/share/' + product['applicationName'])
    os.symlink('../share/' + product['applicationName'] + '/bin/' + product['applicationName'], '/app/bin/' + product['applicationName'])
    for size in [16, 24, 32, 48, 64, 128, 192, 256, 512]:
        size = str(size)
        Path('/app/share/icons/hicolor/' + size + 'x' + size + '/apps').mkdir(parents=True)
        Path('/app/share/icons/hicolor/' + size + 'x' + size + '/apps/' + os.environ['FLATPAK_ID'] + '.png').write_bytes(subprocess.run([
            'magick',
            'convert',
            'vscode/resources/linux/code.png',
            '-resize',
            size + 'x' + size,
            '-'
        ], check=True, stdout=subprocess.PIPE).stdout)

    Path('/app/share/applications').mkdir(parents=True)
    Path('/app/share/applications/' + os.environ['FLATPAK_ID'] + '.desktop').write_text(
        Path('vscode/resources/linux/code.desktop')
        .read_text()
        .replace('Exec=/usr/share/@@NAME@@/@@NAME@@', 'Exec=' + product['applicationName'])
        .replace('@@NAME_LONG@@', product['nameLong'])
        .replace('@@NAME_SHORT@@', product['nameShort'])
        .replace('@@NAME@@', os.environ['FLATPAK_ID'])
        .replace('@@ICON@@', os.environ['FLATPAK_ID'])
    )

    dom = minidom.parse('vscode/resources/linux/code.appdata.xml')

    def remove_white(node):
        if node.nodeType == minidom.Node.TEXT_NODE and node.data.strip() == '':
            node.data = ''
        else:
            list(map(remove_white, node.childNodes))

    remove_white(dom)
    releases = dom.createElement('releases')
    for version, date in METADATA['Releases'].items():
        release = dom.createElement('release')
        release.setAttribute('version', version)
        release.setAttribute('date', date)
        releases.appendChild(release)
    dom.getElementsByTagName('component')[0].appendChild(releases)
    # content_rating = dom.createElement('content_rating')
    # content_rating.setAttribute('type', 'oars-1.1')
    # content_attribute = dom.createElement('content_attribute')
    # content_attribute.setAttribute('id', 'social-info')
    # content_attribute.appendChild(dom.createTextNode('moderate'))
    # content_rating.appendChild(content_attribute)
    # dom.getElementsByTagName('component')[0].appendChild(content_rating)
    description_paragraph_1 = dom.createElement('p')
    description_paragraph_1.appendChild(dom.createTextNode(re.sub(r'\s+', r' ', '''
        This is the Open Source build of Visual Studio Code, packaged into a Flatpak. Some features are
        different from the proprietary version: There is no telemetry nor Twitter integration, and the
        logo is a different one without copyright issue. This OSS repackaging, as well as the proprietary
        repackaging in Flathub, are not supported by Microsoft.
    '''.strip())))
    dom.getElementsByTagName('description')[0].appendChild(description_paragraph_1)
    description_paragraph_2 = dom.createElement('p')
    description_paragraph_2.appendChild(dom.createTextNode(re.sub(r'\s+', r' ', '''
        This OSS build is created due to the proprietarily licensed official binary. For more information,
        see https://github.com/flathub/com.visualstudio.code.oss/issues/6#issuecomment-380152999.
    '''.strip())))
    dom.getElementsByTagName('description')[0].appendChild(description_paragraph_2)
    # for paragraph in dom.getElementsByTagName('p'):
    #     for child in paragraph.childNodes:
    #         if child.nodeType == minidom.Node.TEXT_NODE:
    #             child.data = child.data.replace('https://', '')
    lines = dom.toxml(encoding='UTF-8').decode()
    Path('/app/share/appdata').mkdir(parents=True)
    Path('/app/share/appdata/' + os.environ['FLATPAK_ID'] + '.appdata.xml').write_text(
        lines
        .replace('@@NAME_LONG@@', product['nameLong'])
        .replace('@@NAME@@', os.environ['FLATPAK_ID'])
        .replace('@@LICENSE@@', product['licenseName'])
    )


def main():
    recipe = generate_recipe()
    Path(recipe['app-id'] + '.json').write_text(json.dumps(recipe, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
