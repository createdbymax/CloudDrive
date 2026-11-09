#!/usr/bin/env python3
"""Generate the checked-in native Xcode project using only Python's standard library."""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT/'CloudDrive.xcodeproj'
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = ident(object_name)
    objects[key] = dict(isa=isa, **values)
    return key


def config_list(name, settings):
    configs = []
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug':
            values.update(ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG')
        configs.append(add(name+mode, 'XCBuildConfiguration', buildSettings=values, name=mode))
    return add(name+'configs', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


app = ident('app-target')
helper = ident('helper-target')
core = ident('core-target')
engine = ident('engine-target')
filesystem = ident('filesystem-target')
finder = ident('finder-target')
products = []
phases = {}
for name, folder, product_type, explicit_type, product_path in [
    ('app', 'CloudDrive', 'com.apple.product-type.application', 'wrapper.application', 'CloudDrive.app'),
    ('helper', 'CloudDriveHelper', 'com.apple.product-type.tool', 'compiled.mach-o.executable', 'CloudDriveHelper'),
    ('core', 'CloudDriveCore', 'com.apple.product-type.library.static', 'archive.ar', 'libCloudDriveCore.a'),
    ('engine', 'CloudDriveEngine', 'com.apple.product-type.tool', 'compiled.mach-o.executable', 'CloudDriveEngine'),
    ('filesystem', 'CloudDriveFS', 'com.apple.product-type.extensionkit-extension', 'wrapper.app-extension', 'CloudDriveFS.appex'),
    ('finder', 'CloudDriveFinder', 'com.apple.product-type.app-extension', 'wrapper.app-extension', 'CloudDriveFinder.appex')]:
    refs, builds = [], []
    for source in sorted((ROOT/'Sources'/folder).glob('*.swift')):
        ref = add(str(source.relative_to(ROOT)), 'PBXFileReference', lastKnownFileType='sourcecode.swift',
                  path=source.name, sourceTree='<group>')
        refs.append(ref)
        builds.append(add('build:'+str(source.relative_to(ROOT)), 'PBXBuildFile', fileRef=ref))
    phases[name] = add(name+'compile', 'PBXSourcesBuildPhase', buildActionMask=2147483647,
                       files=builds, runOnlyForDeploymentPostprocessing=0)
    products.append(add(name+'product', 'PBXFileReference', explicitFileType=explicit_type,
                        path=product_path, sourceTree='BUILT_PRODUCTS_DIR'))


def shell(name, script):
    return add(name, 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[],
               inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing=0,
               alwaysOutOfDate=1, name=name, shellPath='/bin/sh', shellScript=script)


preflight = shell('Check signing and inactive app', '''set -eu
cd "$SRCROOT"
python3 scripts/package-app.py --preflight "$TARGET_BUILD_DIR/$WRAPPER_NAME"
backend="${CLOUDDRIVE_BACKEND:-$SRCROOT/build/backend/rclone}"
if [ ! -x "$backend" ]; then
  echo "error: Build the backend once: python3 scripts/build-rclone-allocation.py"
  exit 1
fi
''')
package = shell('Package backend, helper and stable signature', '''set -eu
cd "$SRCROOT"
python3 scripts/package-app.py "$TARGET_BUILD_DIR/$WRAPPER_NAME" "$BUILT_PRODUCTS_DIR" "${CLOUDDRIVE_BACKEND:-$SRCROOT/build/backend/rclone}"
''')
# Seal the bundle only after Xcode has finished generating its Info.plist.
objects[package]['inputPaths'] = ['$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)', '$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)']
proxy = add('helper-proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1,
            remoteGlobalIDString=helper, remoteInfo='CloudDriveHelper')
dep = add('helper-dependency', 'PBXTargetDependency', target=helper, targetProxy=proxy)
common = dict(ALWAYS_SEARCH_USER_PATHS='NO', ARCHS='arm64', ONLY_ACTIVE_ARCH='YES', ENABLE_DEBUG_DYLIB='NO', SWIFT_VERSION='5.0', MACOSX_DEPLOYMENT_TARGET='14.0', SDKROOT='macosx',
              CODE_SIGNING_ALLOWED='NO', ENABLE_USER_SCRIPT_SANDBOXING='NO',
              CLOUDDRIVE_ADHOC_ONLY='0', CLOUDDRIVE_SIGN_IDENTITY='',
              CLOUDDRIVE_INCLUDE_FSKIT='0', CLOUDDRIVE_FSKIT_PROFILE='',
              CLOUDDRIVE_BACKEND='$(SRCROOT)/build/backend/rclone',
              CLOUDDRIVE_SPARKLE_FEED_URL='', CLOUDDRIVE_SPARKLE_PUBLIC_KEY='', CLOUDDRIVE_RELEASE='0',
              CLOUDDRIVE_APP_VERSION='0.5.7', CLOUDDRIVE_APP_BUILD='18',
              PRODUCT_NAME='$(TARGET_NAME)', SWIFT_EMIT_LOC_STRINGS='NO')
app_settings = dict(common, SWIFT_INCLUDE_PATHS=['$(inherited)', '$(BUILT_PRODUCTS_DIR)'], OTHER_LDFLAGS=['-lsqlite3'], PRODUCT_BUNDLE_IDENTIFIER='local.bucketdrive.app',
                    GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_CFBundleDisplayName='CloudDrive', INFOPLIST_KEY_LSApplicationCategoryType='public.app-category.utilities',
                    MARKETING_VERSION='0.5.7', CURRENT_PROJECT_VERSION='18',
                    ENABLE_APP_SANDBOX='NO', COMBINE_HIDPI_IMAGES='YES',
                    LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'])
sparkle_package = add('sparkle-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/sparkle-project/Sparkle', requirement={'kind': 'exactVersion', 'version': '2.10.1'})
sparkle_product = add('sparkle-product', 'XCSwiftPackageProductDependency', package=sparkle_package, productName='Sparkle')
sparkle_build = add('sparkle-link', 'PBXBuildFile', productRef=sparkle_product)
def link_core(name, extra=None):
    linked = add(name+'-core-link', 'PBXBuildFile', fileRef=products[2])
    return add(name+'-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647,
               files=[linked]+(extra or []), runOnlyForDeploymentPostprocessing=0)


def dependency(name, target, product_name):
    proxy = add(name+'-proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1,
                remoteGlobalIDString=target, remoteInfo=product_name)
    return add(name+'-dependency', 'PBXTargetDependency', target=target, targetProxy=proxy)


sparkle_link = link_core('app', [sparkle_build])
core_dependency = dependency('core', core, 'CloudDriveCore')
engine_dependency = dependency('engine', engine, 'CloudDriveEngine')
filesystem_dependency = dependency('filesystem', filesystem, 'CloudDriveFS')
finder_dependency = dependency('finder', finder, 'CloudDriveFinder')
add('app-target', 'PBXNativeTarget' , buildConfigurationList=config_list('app', app_settings),
    buildPhases=[preflight, phases['app'], sparkle_link, package], packageProductDependencies=[sparkle_product], buildRules=[], dependencies=[dep, core_dependency, engine_dependency, filesystem_dependency, finder_dependency],
    name='CloudDrive', productName='CloudDrive', productReference=products[0],
    productType='com.apple.product-type.application')
add('helper-target', 'PBXNativeTarget', buildConfigurationList=config_list('helper', common),
    buildPhases=[phases['helper']], buildRules=[], dependencies=[], name='CloudDriveHelper',
    productName='CloudDriveHelper', productReference=products[1], productType='com.apple.product-type.tool')
add('core-target', 'PBXNativeTarget', buildConfigurationList=config_list('core', dict(common,
    PRODUCT_MODULE_NAME='CloudDriveCore', DEFINES_MODULE='YES', SKIP_INSTALL='YES', OTHER_LDFLAGS=['-lsqlite3'])),
    buildPhases=[phases['core']], buildRules=[], dependencies=[], name='CloudDriveCore',
    productName='CloudDriveCore', productReference=products[2], productType='com.apple.product-type.library.static')
add('engine-target', 'PBXNativeTarget', buildConfigurationList=config_list('engine', dict(common,
    SWIFT_INCLUDE_PATHS=['$(inherited)', '$(BUILT_PRODUCTS_DIR)'], OTHER_LDFLAGS=['-lsqlite3'])),
    buildPhases=[phases['engine'], link_core('engine')], buildRules=[], dependencies=[core_dependency],
    name='CloudDriveEngine', productName='CloudDriveEngine', productReference=products[3], productType='com.apple.product-type.tool')
add('filesystem-target', 'PBXNativeTarget', buildConfigurationList=config_list('filesystem', dict(common,
    MACOSX_DEPLOYMENT_TARGET='26.0', PRODUCT_BUNDLE_IDENTIFIER='local.bucketdrive.app.filesystem',
    GENERATE_INFOPLIST_FILE='YES', INFOPLIST_FILE='Sources/CloudDriveFS/Info.plist',
    CODE_SIGN_ENTITLEMENTS='Sources/CloudDriveFS/CloudDriveFS.entitlements',
    APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES',
    SWIFT_INCLUDE_PATHS=['$(inherited)', '$(BUILT_PRODUCTS_DIR)'], OTHER_LDFLAGS=['-lsqlite3'],
    LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks'])),
    buildPhases=[phases['filesystem'], link_core('filesystem')], buildRules=[], dependencies=[core_dependency],
    name='CloudDriveFS', productName='CloudDriveFS', productReference=products[4], productType='com.apple.product-type.extensionkit-extension')
product_group = add('products', 'PBXGroup', children=products, name='Products', sourceTree='<group>')
add('finder-target', 'PBXNativeTarget', buildConfigurationList=config_list('finder', dict(common,
    PRODUCT_BUNDLE_IDENTIFIER='local.bucketdrive.app.finder', GENERATE_INFOPLIST_FILE='YES',
    INFOPLIST_FILE='Sources/CloudDriveFinder/Info.plist', CODE_SIGN_ENTITLEMENTS='Sources/CloudDriveFinder/CloudDriveFinder.entitlements',
    APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES',
    SWIFT_INCLUDE_PATHS=['$(inherited)', '$(BUILT_PRODUCTS_DIR)'], OTHER_LDFLAGS=['-lsqlite3'],
    LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks'])),
    buildPhases=[phases['finder'], link_core('finder')], buildRules=[], dependencies=[core_dependency],
    name='CloudDriveFinder', productName='CloudDriveFinder', productReference=products[5], productType='com.apple.product-type.app-extension')


def repository_groups():
    # Include new, untracked work too, but respect .gitignore so build outputs,
    # local credentials and Xcode user state never fill the navigator.
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                            cwd=ROOT, check=True, stdout=subprocess.PIPE)
    tree = {}
    for filename in sorted(set(result.stdout.decode().split('\0'))):
        if not filename or not (ROOT/filename).is_file():
            continue
        parts = pathlib.PurePosixPath(filename).parts
        if parts[0] == PROJECT.name:
            continue  # The open project already represents its own bundle.
        branch = tree
        for index, part in enumerate(parts):
            # Treat other Xcode projects and asset bundles as single items.
            if index == len(parts)-1 or pathlib.PurePosixPath(part).suffix in {'.xcodeproj', '.xcworkspace', '.xcassets'}:
                branch[part] = None
                break
            branch = branch.setdefault(part, {})

    file_types = {'.swift': 'sourcecode.swift', '.md': 'net.daringfireball.markdown',
                  '.py': 'text.script.python', '.sh': 'text.script.sh', '.json': 'text.json',
                  '.png': 'image.png', '.xcodeproj': 'wrapper.pb-project',
                  '.xcworkspace': 'wrapper.workspace', '.xcassets': 'folder.assetcatalog'}

    def children(branch, parent=pathlib.PurePosixPath()):
        refs = []
        for name, contents in sorted(branch.items(), key=lambda item: (item[1] is None, item[0].lower())):
            path = parent/name
            if contents is not None:
                refs.append(add('group:'+str(path), 'PBXGroup', children=children(contents, path),
                                path=name, sourceTree='<group>'))
            else:
                refs.append(add(str(path), 'PBXFileReference',
                                lastKnownFileType=file_types.get(path.suffix, 'text'),
                                path=name, sourceTree='<group>'))
        return refs

    return children(tree)


main = add('main-group', 'PBXGroup', children=repository_groups()+[product_group], sourceTree='<group>')
add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2700'},
    buildConfigurationList=config_list('project', {}), compatibilityVersion='Xcode 14.0',
    developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'],
    packageReferences=[sparkle_package], mainGroup=main, productRefGroup=product_group, projectDirPath='', projectRoot='', targets=[app, helper, core, engine, filesystem, finder])


def encode(value):
    if isinstance(value, dict):
        return '{\n'+''.join(f'{json.dumps(str(k))} = {encode(v)};\n' for k,v in value.items())+'}'
    if isinstance(value, list):
        return '('+', '.join(encode(v) for v in value)+')'
    return str(value) if isinstance(value, int) else json.dumps(value)


PROJECT.mkdir(exist_ok=True)
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion=1, classes={}, objectVersion=56,
                                                                objects=objects, rootObject=ident('project')))+'\n')
schemes = PROJECT/'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="CloudDrive.app" BlueprintName="CloudDrive" ReferencedContainer="container:CloudDrive.xcodeproj"/>'
(schemes/'CloudDrive.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(PROJECT)
