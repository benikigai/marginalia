import 'package:dio/dio.dart';

/// Marginalia API service — calls the on-device Cactus inference server
/// running on localhost:8080 (same iPhone).
///
/// Replaces ApiDeepSeekService for the hackathon demo.
class ApiMarginaliaService {
  late Dio _dio;

  /// [serverBase] defaults to localhost (same-device inference).
  /// For MacBook fallback, pass 'http://<macbook-ip>:8080'.
  ApiMarginaliaService({String serverBase = 'http://localhost:8080'}) {
    _dio = Dio(
      BaseOptions(
        baseUrl: serverBase,
        headers: {
          'Content-Type': 'application/json',
        },
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
  }

  /// Send transcribed text to Marginalia, get back 3 tactical options
  /// formatted for G2 lens display.
  Future<String> sendChatRequest(String question) async {
    final data = {
      "text": question,
    };
    print("Marginalia inference request: $data");

    try {
      final response = await _dio.post('/inference-text', data: data);

      if (response.statusCode == 200) {
        print("Marginalia response: ${response.data}");

        final data = response.data;

        // Parse options array from Marginalia response
        if (data is Map && data.containsKey('options')) {
          final options = data['options'] as List;
          return _formatOptionsForLens(options);
        }

        // Fallback: return raw response
        return data.toString();
      } else {
        print("Marginalia request failed: ${response.statusCode}");
        return "Request failed: ${response.statusCode}";
      }
    } on DioException catch (e) {
      if (e.response != null) {
        print("Marginalia error: ${e.response?.statusCode}, ${e.response?.data}");
        return "Error: ${e.response?.statusCode}";
      } else {
        print("Marginalia connection error: ${e.message}");
        // Return dummy response if server unreachable
        return _dummyOptions();
      }
    }
  }

  /// Format 3 options for G2 lens display using confirmed glyphs.
  /// ◉ = selected (U+25C9), ○ = unselected (U+25CB)
  String _formatOptionsForLens(List options) {
    if (options.isEmpty) return "No options available";

    final buffer = StringBuffer();
    for (int i = 0; i < options.length && i < 3; i++) {
      final opt = options[i];
      final label = opt['label'] ?? 'Option ${i + 1}';
      // First option gets the selected glyph
      final glyph = i == 0 ? '\u25C9' : '\u25CB';
      buffer.writeln('$glyph $label');
    }
    return buffer.toString().trimRight();
  }

  /// Fallback response when server is unreachable.
  String _dummyOptions() {
    return '\u25C9 Approve \u2014 block Apr 21-25\n'
           '\u25CB Counter \u2014 ask about workload\n'
           '\u25CB Defer \u2014 send calendar hold';
  }
}
