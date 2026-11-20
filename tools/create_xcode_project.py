#!/usr/bin/env python3
"""Reproducible single-target watch-only Xcode project; no XcodeGen dependency."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1] / 'watch'
PROJECT = ROOT / 'WatchSteer.xcodeproj'
def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

files = ['WatchSteerApp.swift', 'ContentView.swift', 'SteeringController.swift', 'SteeringMath.swift', 'BluetoothTransport.swift', '../shared/BLEProtocol.swift']
objects = []
def add(name, value):
    objects.append(f'{uid(name)} = {{ {value} }};')
def ids(names):
    return ', '.join(uid(n) for n in names) + ','

for f in files:
    add(f, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f}"; sourceTree = "<group>";')
    add('build:'+f, f'isa = PBXBuildFile; fileRef = {uid(f)};')
add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
add('assetsbuild', f'isa = PBXBuildFile; fileRef = {uid("assets")};')
add('plist', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
add('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WatchSteer.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; children = ({uid("app")},); name = Products; sourceTree = "<group>";')
add('root', f'isa = PBXGroup; children = ({ids(files+["plist", "assets", "products"])}); sourceTree = "<group>";')
add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ids(["build:"+f for f in files])}); runOnlyForDeploymentPostprocessing = 0;')
add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("assetsbuild")},); runOnlyForDeploymentPostprocessing = 0;')
for mode in ('Debug', 'Release'):
    project_settings = 'CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; SDKROOT = watchos; WATCHOS_DEPLOYMENT_TARGET = 10.0;'
    project_settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf;' if mode == 'Debug' else ' SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
    add('project'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {project_settings} }};')
    settings = '''CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; DEVELOPMENT_TEAM = "";
    ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Info.plist; MARKETING_VERSION = 0.1.0;
    PRODUCT_BUNDLE_IDENTIFIER = com.example.WatchSteer; PRODUCT_NAME = "$(TARGET_NAME)";
    SDKROOT = watchos; SUPPORTED_PLATFORMS = "watchos watchsimulator"; TARGETED_DEVICE_FAMILY = 4;
    SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_VERSION = 5.0; ENABLE_USER_SCRIPT_SANDBOXING = YES;
    LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
    add('target'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {settings} }};')
for kind in ('project', 'target'):
    add(kind+'config', f'isa = XCConfigurationList; buildConfigurations = ({ids([kind+"Debug",kind+"Release"])}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'''isa = PBXNativeTarget; buildConfigurationList = {uid('targetconfig')};
buildPhases = ({ids(['sources','frameworks','resources'])}); buildRules = (); dependencies = ();
name = WatchSteer; productName = WatchSteer; productReference = {uid('app')}; productType = "com.apple.product-type.application";''')
add('project', f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700;
TargetAttributes = {{ {uid('target')} = {{ CreatedOnToolsVersion = 27.0; }}; }}; }};
buildConfigurationList = {uid('projectconfig')}; compatibilityVersion = "Xcode 14.0";
developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base);
mainGroup = {uid('root')}; productRefGroup = {uid('products')}; projectDirPath = "";
projectRoot = ""; targets = ({uid('target')},);''')
PROJECT.mkdir(exist_ok=True)
(PROJECT / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = '+uid('project')+'; }\n')
scheme = PROJECT / 'xcshareddata/xcschemes/WatchSteer.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="WatchSteer.app" BlueprintName="WatchSteer" ReferencedContainer="container:WatchSteer.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Created', PROJECT)
