// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_writer/yaml_writer.dart';
import 'package:http/http.dart' as http;


abstract class DeploymentTask {
  FutureOr<void> run();
}

const gitOpsApiUrl = 'https://api.github.com/repos/infostrategytech/mobile-gitops';
const githubToken = 'Bearer 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';
const dependenciesKey = 'dependencies';
const dependenciesOverrideKey = 'dependency_overrides';
const envKey = 'env';
const localeKey = 'locale';
const configKey = 'config';
const refKey = 'gitops-ref';
const _buildType = 'build-type';
const allowedEnv = ['dev', 'staging', 'prod'];
const allowedBuildType = ['composite', 'local'];

String dartDefineFile = "";

/// Main class
void main(List<String> args) async {
  final parser = ArgParser();

  parser
    ..addOption(dependenciesKey, abbr: 'd')
    ..addOption(configKey, abbr: 'c')
    ..addOption(envKey, defaultsTo: 'dev', allowed: allowedEnv)
    ..addOption(localeKey, defaultsTo: 'accelerate')
    ..addOption(refKey, defaultsTo: 'main')
    ..addCommand('tag');

  final buildParser = parser.addCommand('build');

  buildParser
    ..addOption(_buildType, defaultsTo: 'local', allowed: allowedBuildType)
    ..addOption('id', abbr: 'i')
    ..addCommand('android')
    ..addCommand('ios');

  final ArgResults results = parser.parse(args);

  final buildEnvironment = BuildEnvironment.valueOf(results[envKey]);
  final locale = results[localeKey];
  final gitRef = results[refKey];

  if (results.command?.name == 'tag') {
    return TagApplicationTask(gitRef, buildEnvironment, locale).run();
  }

  await ApplicationTestTask().run();

  final ArgResults? command = results.command;

  switch (command?.name) {
    case 'build':
      {
        return BuildCommand(
            args: command!,
            locale: locale,
            environment: buildEnvironment,
            configMap: (null != results[configKey])
                ? jsonDecode(results[configKey])
                : await fetchJsonFile(buildEnvironment, locale, gitRef))
            .execute();
      }
    default:
      print(command?.name);
  }
}

///===================Responsible for initiating test ==========================
class ApplicationTestTask implements DeploymentTask {
  @override
  FutureOr<void> run() async {
    Process.runSync('dart', ['pub', 'global', 'activate', 'junitreport']);
    Process.runSync('dart', ['pub', 'global', 'activate', 'dart_code_metrics']);

    await addDependenciesAndBuild();

    // const command = 'flutter test --machine --coverage | tojunit -o report.xml';
    // const metricCommand = 'metrics lib -r codeclimate  > gl-code-quality-report.json';
    // final path = '${Platform.environment['PATH']}:${Platform.environment['HOME']}/.pub-cache/bin';
    // Process.runSync('/bin/sh', ['-c', command], environment: {'PATH': path});
    // Process.runSync('/bin/sh', ['-c', metricCommand], environment: {'PATH': path});
  }
}

///===================Responsible for Building application =====================
class PostPublishingTask implements DeploymentTask {
  @override
  void run() {}
}

///
class BuildCommand {
  final ArgResults args;
  final BuildEnvironment environment;
  final Map<String, dynamic> configMap;
  final String locale;

  BuildCommand({
    required this.args,
    required this.environment,
    required this.configMap,
    required this.locale,
  }) {
    setConfigMapEnvironment(configMap);
  }

  void setConfigMapEnvironment(Map<String, dynamic> config) {
    final configs = Map.from(config);
    configs['config'] = jsonEncode(configs['config']);
    final configMapEnv = jsonEncode(configs);
    final tempFile = Directory.systemTemp;
    final file = File(
        '${tempFile.path}/config_${DateTime.now().millisecondsSinceEpoch}.json');
    file.writeAsStringSync(configMapEnv);
    dartDefineFile = file.path;
  }

  void execute() async {
    print('Executing android build');
    final BuildType buildType = BuildType.valueOf(args[_buildType]);
    final appId = args['id'];

    switch (args.command?.name) {
      case 'ios':
        IOSPublishingTask(environment, buildType, configMap, appId).run();
        break;
      case 'android':
        AndroidPublishingTask(environment, buildType, configMap).run();
        break;
      default:
        AndroidPublishingTask(environment, buildType, configMap).run();
        print(
            'App ID is $buildType  ====> $appId   ====> ${configMap.toString()}');
        IOSPublishingTask(environment, buildType, configMap, appId).run();
    }
  }
}

///===================Responsible for Android Build ============================
class AndroidPublishingTask implements DeploymentTask {
  final BuildEnvironment environment;
  final BuildType buildType;
  final Map<String, dynamic> configMap;

  AndroidPublishingTask(this.environment, this.buildType, this.configMap);

  Future<Process> buildRelease(String type) async {
    return await runCommand('flutter', [
      'build',
      type,
      '--release',
      if (type != 'appbundle') '--split-per-abi',
      '--dart-define=APP_ENV=${environment.name}',
      '--dart-define-from-file=$dartDefineFile',
      '--flavor=${environment.name}',
      '--build-name=${Platform.environment['APP_BUILD_NAME']}',
      '--build-number=${Platform.environment['ANDROID_LATEST_BUILD_NUMBER']}',
    ]);
  }

  @override
  void run() {
    final fciBuildDir = Platform.environment['FCI_BUILD_DIR'];
    final homeDir = Platform.environment['HOME'];
    if (fciBuildDir != null) {
      Process.runSync('echo', [
        'flutter.sdk=$homeDir/programs/flutter',
        '>',
        '$fciBuildDir/android/local.properties'
      ]);
    }

    if (buildType == BuildType.composite) {
      buildRelease('apk').then((value) {
        if (environment == BuildEnvironment.prod) {
          buildRelease('appbundle');
        }
      });
    }
  }
}

///===================Responsible for IOS Build  ===============================
class IOSPublishingTask implements DeploymentTask {
  final BuildEnvironment environment;
  final BuildType buildType;
  final Map<String, dynamic> configMap;
  final String appId;

  IOSPublishingTask(
      this.environment, this.buildType, this.configMap, this.appId);

  int getLatestBuildNumber(String currentVersion, String appId) {
    final command =
        'app-store-connect builds list --pre-release-version "$currentVersion"'
        ' --app-id "$appId" --json';
    final results = Process.runSync('/bin/sh', ['-c', command]);
    try {
      final body = jsonDecode(results.stdout.toString()) as List<dynamic>;
      final preReleaseItem = body.lastOrNull as Map<String, dynamic>?;
      final version = preReleaseItem?['attributes']?['version'] ?? "";
      return int.tryParse(version) ?? 0;
    } on FormatException {
      return 0;
    }
  }

  void buildRelease() async {
    final iosVersion = Platform.environment['APP_BUILD_NAME'] ?? '';
    final nextBuildNumber = getLatestBuildNumber(iosVersion, appId) + 1;
    await runCommand('flutter', [
      'build',
      'ipa',
      '--release',
      '--dart-define=APP_ENV=${environment.name}',
      '--dart-define-from-file=$dartDefineFile',
      '--flavor=${environment.name}',
      '--build-name=$iosVersion',
      '--build-number=$nextBuildNumber',
      '--export-options-plist=/Users/builder/export_options.plist'
    ], environment: {
      'FLUTTER_BUILD_NAME': iosVersion,
      'FLUTTER_BUILD_NUMBER': '$nextBuildNumber'
    });
  }

  @override
  void run() async {
    await runCommand('xcode-project', ['use-profiles']);
    buildRelease();
  }
}

///
class TagApplicationTask implements DeploymentTask {
  TagApplicationTask(this.ref, this.buildEnvironment, this.locale);

  final String ref;
  final BuildEnvironment buildEnvironment;
  final String locale;

  bool isVersionGreaterThan(String version1, String version2) {
    List<int> v1Components = version1.split('.').map(int.parse).toList();
    List<int> v2Components = version2.split('.').map(int.parse).toList();
    for (int i = 0; i < v1Components.length; i++) {
      if (v1Components[i] > v2Components[i]) {
        return true;
      } else if (v1Components[i] < v2Components[i]) {
        return false;
      }
    }
    return false;
  }

  Future<String> getNextVersionNumber() async {
    final latestTag =
    Process.runSync('git', ['describe', '--tags', '--abbrev=0'])
        .stdout
        .toString()
        .trim();

    var major = 0;
    var minor = 0;
    var patch = 0;

    if (latestTag.isNotEmpty) {
      String version = RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+')
          .firstMatch(latestTag)
          ?.group(0)
          ?.substring(1) ??
          '';

      List<String> versionArray = version.split('.');
      major = int.tryParse(versionArray[0]) ?? 0;
      minor = int.tryParse(versionArray[1]) ?? 0;
      patch = int.tryParse(versionArray[2]) ?? 0;
    }

    final currentAppVersion = Platform.environment['APP_BUILD_NAME'] ?? "0.0.0";
    final latestAppTagVersion = "$major.$minor.$patch";
    var newAppTagVersion = currentAppVersion;
    final buildName = buildEnvironment == BuildEnvironment.prod
        ? "rc"
        : buildEnvironment.name;

    if (currentAppVersion == latestAppTagVersion) {
      final lastNumber = int.parse(latestTag.split(".").lastOrNull ?? "0") + 1;
      final buildName = buildEnvironment == BuildEnvironment.prod
          ? "rc"
          : buildEnvironment.name;
      newAppTagVersion = "$latestAppTagVersion.$buildName.$lastNumber";
    } else if (isVersionGreaterThan(currentAppVersion, latestAppTagVersion)) {
      newAppTagVersion = "$currentAppVersion.$buildName.1";
    } else {
      print('Do nothing for now');
    }
    return "v$newAppTagVersion";
  }

  @override
  void run() async {
    if (['main', 'develop', 'staging'].contains(ref)) {
      final nextVersionNumber = await getNextVersionNumber();
      print('TagApplicationTaskVersionNumber: $nextVersionNumber');
      final gitOpsTag = "$nextVersionNumber.$locale";
      Process.runSync(
          'git', ['tag', '-a', nextVersionNumber, '-m', "'GitOps:$gitOpsTag'"]);
      Process.runSync('git', ['push', 'origin', nextVersionNumber]);
      final urlPath =
          '$gitOpsApiUrl/tags?tag_name=$gitOpsTag&message=$locale&ref=$ref';
      final response = await http
          .post(Uri.parse(urlPath), headers: {'Authorization': githubToken,"Accept": "application/vnd.github+json"});
      final responseBody = jsonDecode(response.body);
      print("Response : $responseBody");
      print('TagApplicationTask: ${responseBody['name']}');
    }
  }
}

enum BuildEnvironment {
  dev,
  staging,
  prod;

  factory BuildEnvironment.valueOf(String value) {
    return BuildEnvironment.values.firstWhere(
          (element) => element.name.toLowerCase() == value.toLowerCase(),
      orElse: () {
        return BuildEnvironment.dev;
      },
    );
  }
}

enum BuildType {
  composite,
  local;

  factory BuildType.valueOf(String value) {
    return BuildType.values.firstWhere(
          (element) => element.name.toLowerCase() == value.toLowerCase(),
      orElse: () {
        return BuildType.local;
      },
    );
  }
}

Future<dynamic> addDependenciesAndBuild() async {
  await runCommand('flutter', ['pub', 'get']);
  await runCommand(
      'dart', ['run', 'build_runner', 'build', '--delete-conflicting-outputs']);
}

Future<Process> runCommand(String executable, List<String> arguments,
    {Map<String, String>? environment}) async {
  final Completer<Process> completer = Completer();
  final result =
  await Process.start(executable, arguments, environment: environment);
  result.stdout.listen((List<int> data) => print(String.fromCharCodes(data)),
      onDone: () {
        completer.complete(result);
      }, onError: (a) {
        completer.completeError(a);
      });
  result.stderr.listen((List<int> data) => print(String.fromCharCodes(data)));
  return completer.future;
}

Future<Map<String, dynamic>> fetchJsonFile(
    BuildEnvironment environment, String locale, String ref,
    {String fileType = 'config'}) async {
  print('<====== Fetching $fileType from gitOps =====>');
  final filePath = '${environment.name}/$locale/$fileType.json';
  final urlPath =
      '$gitOpsApiUrl/contents/$filePath?ref=$ref';
  print('GitOps URL : $urlPath');
  final response = await http.get(Uri.parse(urlPath), headers: {
    'Authorization': githubToken,
    "Accept": "application/vnd.github+json"
  });
  final responseBody = jsonDecode(response.body);
  print('<====== Response of  $fileType from gitOps =====>');
  print('$responseBody');
  final jsonContent = utf8.decode(base64.decode(responseBody['content']));
  return (jsonContent.trim().isNotEmpty) ? jsonDecode(jsonContent) : {};
}
