typedef ChatChunk = ({String text, bool thinking});

/// Separates models that embed `<think>` in content, even across stream chunks.
class ChatReasoning {
  static const _start = '<think>';
  static const _end = '</think>';
  static final _startTag = RegExp(_start, caseSensitive: false);
  static final _endTag = RegExp(_end, caseSensitive: false);
  String _pending = '';
  bool _thinking = false;

  Iterable<ChatChunk> add(String text) sync* {
    var buffer = _pending + text;
    _pending = '';
    while (buffer.isNotEmpty) {
      final marker = _thinking ? _end : _start;
      final tag = (_thinking ? _endTag : _startTag).firstMatch(buffer);
      if (tag != null) {
        if (tag.start > 0) {
          yield (text: buffer.substring(0, tag.start), thinking: _thinking);
        }
        buffer = buffer.substring(tag.end);
        _thinking = !_thinking;
        continue;
      }
      var split = buffer.length;
      for (
        var length = 1;
        length < marker.length && length <= buffer.length;
        length++
      ) {
        final start = buffer.length - length;
        if (buffer.substring(start).toLowerCase() ==
            marker.substring(0, length)) {
          split = start;
        }
      }
      if (split > 0) {
        yield (text: buffer.substring(0, split), thinking: _thinking);
      }
      _pending = buffer.substring(split);
      break;
    }
  }

  ChatChunk finish() => (text: _pending, thinking: _thinking);
}
