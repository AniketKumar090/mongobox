import 'dart:math' as math;

/// Lightweight semantic reranker with hashed n-gram embeddings.
///
/// This keeps ranking fully local (no paid API), while improving lyric-line
/// matching for noisy or partial text.
class SemanticRerankerService {
  static const int _dims = 256;
  static const double _titleBoost = 1.1;
  static const double _artistBoost = 0.9;
  static const double _evidenceBoost = 1.3;

  double score({
    required String query,
    required String trackName,
    required String artistName,
    String? evidenceText,
  }) {
    final q = _normalize(query);
    if (q.isEmpty) return 0;

    final queryVec = _embed(q, weight: 1.0);
    final titleVec = _embed(_normalize(trackName), weight: _titleBoost);
    final artistVec = _embed(_normalize(artistName), weight: _artistBoost);
    final evidenceVec = _embed(_normalize(evidenceText ?? ''), weight: _evidenceBoost);

    final candidateVec = _merge([titleVec, artistVec, evidenceVec]);
    final cosine = _cosine(queryVec, candidateVec);

    final tokenCoverage = _tokenCoverage(q, '${_normalize(trackName)} ${_normalize(artistName)} ${_normalize(evidenceText ?? '')}');
    final phraseBonus = _phraseOverlap(q, _normalize(evidenceText ?? trackName));

    // Blend semantic + lexical signals. Clamp to 0..1 for safe confidence use.
    final blended = (0.65 * cosine) + (0.25 * tokenCoverage) + (0.10 * phraseBonus);
    if (blended < 0) return 0;
    if (blended > 1) return 1;
    return blended;
  }

  List<double> _embed(String text, {required double weight}) {
    final out = List<double>.filled(_dims, 0.0);
    if (text.isEmpty) return out;

    final tokens = text.split(' ').where((t) => t.isNotEmpty).toList();
    for (final token in tokens) {
      _addFeature(out, token, weight);

      if (token.length >= 3) {
        for (var i = 0; i <= token.length - 3; i++) {
          _addFeature(out, token.substring(i, i + 3), weight * 0.65);
        }
      }
      if (token.length >= 4) {
        for (var i = 0; i <= token.length - 4; i++) {
          _addFeature(out, token.substring(i, i + 4), weight * 0.5);
        }
      }
    }

    return _l2Normalize(out);
  }

  void _addFeature(List<double> vector, String feature, double weight) {
    final h = feature.hashCode.abs();
    final idx = h % _dims;
    final sign = (h & 1) == 0 ? 1.0 : -1.0;
    vector[idx] += sign * weight;
  }

  List<double> _merge(List<List<double>> vectors) {
    final out = List<double>.filled(_dims, 0.0);
    for (final vec in vectors) {
      for (var i = 0; i < _dims; i++) {
        out[i] += vec[i];
      }
    }
    return _l2Normalize(out);
  }

  List<double> _l2Normalize(List<double> vector) {
    var sumSq = 0.0;
    for (final v in vector) {
      sumSq += v * v;
    }
    if (sumSq <= 0) return vector;
    final norm = math.sqrt(sumSq);
    return vector.map((v) => v / norm).toList(growable: false);
  }

  double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    for (var i = 0; i < _dims; i++) {
      dot += a[i] * b[i];
    }
    // Cosine in [-1, 1] -> convert to [0, 1]
    return (dot + 1) / 2;
  }

  double _tokenCoverage(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    final q = query.split(' ').where((w) => w.length > 1).toSet();
    final c = candidate.split(' ').where((w) => w.length > 1).toSet();
    if (q.isEmpty || c.isEmpty) return 0;
    final common = q.intersection(c).length.toDouble();
    return common / q.length;
  }

  double _phraseOverlap(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    if (candidate.contains(query) || query.contains(candidate)) return 1;

    final q = query.split(' ').where((w) => w.length > 1).toList();
    final c = candidate.split(' ').where((w) => w.length > 1).toList();
    if (q.isEmpty || c.isEmpty) return 0;

    var best = 0;
    for (var i = 0; i < q.length; i++) {
      for (var j = 0; j < c.length; j++) {
        var k = 0;
        while (i + k < q.length && j + k < c.length && q[i + k] == c[j + k]) {
          k++;
        }
        if (k > best) best = k;
      }
    }
    return best / q.length;
  }

  String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}
