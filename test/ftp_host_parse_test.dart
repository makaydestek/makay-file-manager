import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/remote_service.dart';

void main() {
  test('FTP IP ve UNC yapıştırması host olarak çözülür', () {
    expect(FtpClientService.stripHost('192.168.68.180'), '192.168.68.180');
    expect(FtpClientService.stripHost(r'\\192.168.68.180'), '192.168.68.180');
    expect(FtpClientService.stripHost(r'\\192.168.68.180\photo'), '192.168.68.180');
    expect(FtpClientService.stripHost('ftp://192.168.68.180/photo'), '192.168.68.180');
    expect(FtpClientService.parseHostPort('192.168.68.180:21').$2, 21);
  });
}
