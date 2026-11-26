import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_mobile/remote.dart';

void main() {
  test('desktop snapshots preserve known and unknown model availability', () {
    final snapshot = Snapshot.read({
      'models': [
        {'id': 'ollama', 'name': 'Ollama', 'kind': 'local', 'available': true},
        {'id': 'cloud', 'name': '云端模型', 'kind': 'cloud', 'available': false},
        {'id': 'legacy', 'name': '未验证模型', 'kind': 'cloud'},
        {'id': 'invalid', 'kind': 'local'},
      ],
    }, remote: true);
    expect(snapshot.models.map((model) => model.name), [
      'Ollama',
      '云端模型',
      '未验证模型',
    ]);
    expect(snapshot.models.map((model) => model.available), [
      true,
      false,
      null,
    ]);
    expect(snapshot.models.first.local, isTrue);
    expect(Snapshot.read({}).models, isEmpty);
  });
}
