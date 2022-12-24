import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localsend_app/main.dart';
import 'package:localsend_app/model/dto/info_dto.dart';
import 'package:localsend_app/model/dto/send_request_dto.dart';
import 'package:localsend_app/model/server/receive_state.dart';
import 'package:localsend_app/model/server/receiving_file.dart';
import 'package:localsend_app/model/server/server_state.dart';
import 'package:localsend_app/model/session_status.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/routes.dart';
import 'package:localsend_app/service/persistence_service.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/api_route_builder.dart';
import 'package:localsend_app/util/device_info_helper.dart';
import 'package:localsend_app/util/file_path_helper.dart';
import 'package:path_provider/path_provider.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

/// This provider manages receiving file requests.
final serverProvider = StateNotifierProvider<ServerNotifier, ServerState?>((ref) {
  final deviceInfo = ref.watch(deviceRawInfoProvider);
  return ServerNotifier(ref, deviceInfo);
});

const _uuid = Uuid();

class ServerNotifier extends StateNotifier<ServerState?> {
  final DeviceInfoResult deviceInfo;
  final Ref _ref;

  ServerNotifier(this._ref, this.deviceInfo) : super(null);

  Future<ServerState?> startServer({required String alias, required int port}) async {
    if (state != null) {
      print('Server already running.');
      return null;
    }

    alias = alias.trim();
    if (alias.isEmpty) {
      alias = generateRandomAlias();
    }

    if (port < 0 || port > 65535) {
      port = defaultPort;
    }

    final router = Router();

    final String destinationDir;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        destinationDir = '/storage/emulated/0/Download';
        break;
      case TargetPlatform.iOS:
        destinationDir = (await path.getApplicationDocumentsDirectory()).path;
        break;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        destinationDir = (await path.getDownloadsDirectory())!.path;
        break;
    }

    print('Destination Directory: $destinationDir');
    _configureRoutes(router, alias, port, destinationDir);

    print('Starting server...');
    ServerState? newServerState;
    try {
      newServerState = ServerState(
        httpServer: await serve(router, '0.0.0.0', port),
        alias: alias,
        port: port,
        receiveState: null,
      );
      print('Server started. (Port: ${newServerState.port})');
    } catch (e) {
      print(e);
    }

    state = newServerState;
    return newServerState;
  }

  void _configureRoutes(Router router, String alias, int port, String tempDir) {
    router.get(ApiRoute.info.path, (Request request) {
      final dto = InfoDto(
        alias: alias,
        deviceModel: deviceInfo.deviceModel,
        deviceType: deviceInfo.deviceType,
      );
      return Response.ok(jsonEncode(dto.toJson()), headers: {'Content-Type': 'application/json'});
    });

    router.post(ApiRoute.sendRequest.path, (Request request) async {
      if (state!.receiveState != null) {
        // block incoming requests when we are already in a session
        return Response.badRequest();
      }

      final payload = await request.readAsString();
      final dto = SendRequestDto.fromJson(jsonDecode(payload));
      final streamController = StreamController<bool>();
      state = state!.copyWith(
        receiveState: ReceiveState(
          status: SessionStatus.waiting,
          sender: dto.info.toDevice(request.ip, port),
          files: {
            for (final file in dto.files.values)
              file.id: ReceivingFile(
                file: file,
                token: null,
                tempPath: null,
              ),
          },
          responseHandler: streamController,
        ),
      );

      // ignore: use_build_context_synchronously
      const ReceiveRoute().push(LocalSendApp.routerContext);

      // Delayed response (waiting for user's decision)
      final result = await streamController.stream.first;
      if (result) {
        return Response.ok(jsonEncode({
          for (final file in state!.receiveState!.files.values)
            file.file.id: file.token,
        }), headers: {'Content-Type': 'application/json'});
      } else {
        return Response.badRequest();
      }
    });

    router.post(ApiRoute.send.path, (Request request) async {
      final receiveState = state?.receiveState;
      if (receiveState == null || request.ip != receiveState.sender.ip) {
        // reject because there is no session or IP does not match session
        print('No session or wrong IP');
        return Response.badRequest();
      }

      final fileId = request.url.queryParameters['fileId'];
      final token = request.url.queryParameters['token'];
      if (fileId == null || token == null) {
        // reject because of missing parameters
        print('Missing parameters');
        return Response.badRequest();
      }

      final receivingFile = receiveState.files[fileId];
      if (receivingFile == null || receivingFile.token != token) {
        // reject because there is no file or token does not match
        print('Wrong token');
        return Response.badRequest();
      }

      // begin of actual file transfer
      String destinationPath = '$tempDir/${receivingFile.file.fileName}';
      File testFile;
      int counter = 1;
      do {
        destinationPath = counter == 1 ? '$tempDir/${receivingFile.file.fileName}' : '$tempDir/${receivingFile.file.fileName.withCount(counter)}';
        testFile = File(destinationPath);
        counter++;
      } while(await testFile.exists());

      print('Saving ${receivingFile.file.fileName} to $destinationPath');

      final destinationFile = File(destinationPath).openWrite();
      int lastNotifyBytes = 0;
      int currByte = 0;
      final subscription = request.read().listen((event) {
        destinationFile.add(event);
        currByte += event.length;
        if (currByte - lastNotifyBytes >= 100 * 1024 && receivingFile.file.size != 0) {
          // update progress every 100 KB
          lastNotifyBytes = currByte;
          _ref.read(progressProvider.notifier).setProgress(fileId, currByte / receivingFile.file.size);
        }
      });
      await subscription.asFuture();
      await destinationFile.close();
      print('Saved ${receivingFile.file.fileName}.');

      final progressNotifier = _ref.read(progressProvider.notifier);
      progressNotifier.setProgress(fileId, 1);

      if (receiveState.files.values.every((f) => f.token == null || progressNotifier.getProgress(f.file.id) == 1)) {
        state = state?.copyWith(
          receiveState: receiveState.copyWith(
            status: SessionStatus.finished,
          ),
        );
        print('Received all files.');
      }

      return Response.ok('');
    });

    router.post(ApiRoute.cancel.path, (Request request) {
      final ip = request.context['shelf.io.connection_info'] as HttpConnectionInfo;

      if (state?.receiveState?.sender.ip == ip.remoteAddress.address) {
        _cancelBySender();
      }

      return Response.ok('');
    });
  }

  Future<void> stopServer() async {
    await state?.httpServer.close(force: true);
    state = null;
    print('Server stopped.');
  }

  Future<ServerState?> restartServer({required String alias, required int port}) async {
    await stopServer();
    return await startServer(alias: alias, port: port);
  }

  void acceptFileRequest(Set<String> fileIds) {
    final receiveState = state?.receiveState;
    if (receiveState == null) {
      return;
    }

    final responseHandler = receiveState.responseHandler;
    if (responseHandler == null) {
      return;
    }

    state = state?.copyWith(
      receiveState: receiveState.copyWith(
        files: {
          for (final file in receiveState.files.values)
            file.file.id: ReceivingFile(
              file: file.file,
              token: fileIds.contains(file.file.id) ? _uuid.v4() : null,
              tempPath: null,
            ),
        },
        responseHandler: null,
      ),
    );

    responseHandler.add(true);
    responseHandler.close();
  }

  void declineFileRequest() {
    final controller = state?.receiveState?.responseHandler;
    if (controller == null) {
      return;
    }

    controller.add(false);
    controller.close();
    closeSession();
  }

  void _cancelBySender() {
    state = state?.copyWith(
      receiveState: state?.receiveState?.copyWith(
        status: SessionStatus.canceledBySender,
      ),
    );
  }

  void closeSession() {
    state = state?.copyWith(
      receiveState: null,
    );
  }
}

extension on Request {
  String get ip {
    return (context['shelf.io.connection_info'] as HttpConnectionInfo).remoteAddress.address;
  }
}