import 'dart:convert';

import 'chat_reasoning.dart';

const modelResponseTimeout = Duration(seconds: 120);
const modelRelayTimeout = Duration(seconds: 135);
const reasoningPreviewLimit = 48000;

Stream<ChatChunk> readChatCompletion(Stream<String> lines) async* {
  final inline = ChatReasoning();
  final reasoning = StringBuffer();
  final answer = StringBuffer();
  final jsonBody = StringBuffer();
  var explicitReasoning = false;
  var hasAnswer = false;
  var finished = false;
  String? finishReason;
  var cumulativeReasoning = false;

  String nextReasoning(String value, {bool snapshot = false}) {
    if (value.isEmpty) return '';
    final length = reasoning.length;
    if (length > 0 &&
        value.length > length &&
        value.startsWith(reasoning.toString())) {
      cumulativeReasoning = true;
      value = value.substring(length);
    } else if ((snapshot || cumulativeReasoning) &&
        length >= value.length &&
        reasoning.toString().startsWith(value)) {
      return '';
    }
    reasoning.write(value);
    return value;
  }

  Iterable<ChatChunk> readFrame(Object? frame) sync* {
    if (frame is! Map) return;
    if (frame['error'] != null) {
      throw const ChatCompletionFailure('模型服务返回错误。');
    }
    final choices = frame['choices'];
    final choice = choices is List ? choices.firstOrNull : null;
    if (choice is! Map) return;
    final stop = choice['finish_reason'];
    if (stop is String && stop.isNotEmpty) {
      finishReason = stop;
      finished = true;
    }
    final delta = choice['delta'];
    final message = delta is Map ? delta : choice['message'];
    if (message is! Map) return;
    final trace = _text(message['reasoning_content'] ?? message['reasoning']);
    if (trace.isNotEmpty) {
      explicitReasoning = true;
      final addition = nextReasoning(trace, snapshot: delta is! Map);
      if (addition.isNotEmpty) yield (text: addition, thinking: true);
    }
    var text = _text(message['content']);
    if (delta is! Map &&
        answer.isNotEmpty &&
        text.startsWith(answer.toString())) {
      text = text.substring(answer.length);
    }
    for (final part in inline.add(text)) {
      if (part.thinking) {
        if (explicitReasoning) continue;
        final addition = nextReasoning(part.text);
        if (addition.isNotEmpty) yield (text: addition, thinking: true);
      } else {
        hasAnswer |= part.text.trim().isNotEmpty;
        answer.write(part.text);
        yield part;
      }
    }
  }

  await for (final line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('data:')) {
      final data = trimmed.substring(5).trim();
      if (data == '[DONE]') {
        finished = true;
        break;
      }
      if (data.isNotEmpty) {
        for (final chunk in readFrame(jsonDecode(data))) {
          yield chunk;
        }
      }
    } else if (jsonBody.isNotEmpty || trimmed.startsWith('{')) {
      jsonBody.writeln(line);
    }
  }
  if (jsonBody.isNotEmpty) {
    final frame = jsonDecode(jsonBody.toString());
    for (final chunk in readFrame(frame)) {
      yield chunk;
    }
  }

  final tail = inline.finish();
  if (tail.text.isNotEmpty) {
    if (!tail.thinking) {
      hasAnswer |= tail.text.trim().isNotEmpty;
      yield tail;
    } else if (!explicitReasoning) {
      yield tail;
    }
  }
  if (!finished) {
    throw const ChatCompletionFailure('模型连接在回复完成前中断。');
  }
  if (!hasAnswer) {
    throw ChatCompletionFailure(switch (finishReason) {
      'length' => '模型达到输出长度上限，尚未生成正文。可缩短问题或调低思考等级后重试。',
      'content_filter' || 'refusal' => '模型服务拦截了本次回复。',
      'tool_calls' || 'function_call' => '模型请求调用工具，未生成可显示的正文。',
      _ when reasoning.isNotEmpty => '模型只返回了思考过程，未生成正文。',
      _ => '模型未返回可显示的文字。请检查模型是否兼容 Chat Completions 接口。',
    });
  }
}

String _text(Object? value) {
  if (value is String) return value;
  if (value is! List) return '';
  return value.whereType<Map>().map((part) {
    final text = part['text'];
    return text is String ? text : '';
  }).join();
}

class ChatCompletionFailure extends FormatException {
  const ChatCompletionFailure(super.message);
}
