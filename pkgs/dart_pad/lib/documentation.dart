// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert' as convert show htmlEscape;
import 'dart:html';

import 'package:dartpad_shared/services.dart';
import 'package:markdown/markdown.dart' as markdown;

import 'context.dart';
import 'dart_pad.dart';
import 'editing/editor.dart';
import 'services/common.dart';
import 'src/util.dart';
import 'util/detect_flutter.dart';

class DocHandler {
  static const Set<int> cursorKeys = {
    KeyCode.LEFT,
    KeyCode.RIGHT,
    KeyCode.UP,
    KeyCode.DOWN
  };

  final Editor _editor;
  final ContextBase _sourceProvider;

  final NodeValidator _htmlValidator = PermissiveNodeValidator();

  int? _previousDocHash;

  DocHandler(this._editor, this._sourceProvider);

  void generateDoc(List<DivElement> docElements) {
    if (docElements.isEmpty) {
      return;
    }

    if (!_sourceProvider.isFocused) {
      _previousDocHash = null;
      for (final docPanel in docElements) {
        docPanel.innerHtml = '';
      }
      return;
    }
    if (!_editor.hasFocus || _editor.document.selection.isNotEmpty) {
      return;
    }

    final offset = _editor.document.indexFromPos(_editor.document.cursor);

    dartServices
        .document(SourceRequest(
          source: _sourceProvider.dartSource,
          offset: offset,
        ))
        .timeout(documentServiceTimeout)
        .then((DocumentResponse result) {
      final hash = result.hashCode;
      // If nothing has changed, don't need to parse Markdown and
      // manipulate HTML again.
      if (hash == _previousDocHash) {
        return;
      }
      _previousDocHash = hash;

      final docResult = _getHtmlTextFor(result);

      final docType = 'type-${docResult.entityKind}';
      for (final docPanel in docElements) {
        docPanel.setInnerHtml(docResult.html, validator: _htmlValidator);
        for (final a in docPanel.querySelectorAll('a')) {
          if (a is AnchorElement) a.target = 'docs';
        }
        for (final h in docPanel.querySelectorAll('h1')) {
          h.classes.add(docType);
        }
      }
    });
  }

  _DocResult _getHtmlTextFor(DocumentResponse result) {
    if (result.elementDescription == null && result.dartdoc == null) {
      return _DocResult('');
    }

    final libraryName = result.containingLibraryName;
    final kind = result.elementKind;
    final hasDartdoc = result.dartdoc != null;
    final isVariable = kind?.contains('variable') ?? false;

    final apiLink = _dartApiLink(libraryName);

    final propagatedType = result.propagatedType;
    final mdDocs = '''# `${result.elementDescription}`\n\n
${hasDartdoc ? "${result.dartdoc}\n\n" : ''}
${isVariable ? "$kind\n\n" : ''}
${(isVariable && propagatedType != null) ? "**Propagated type:** $propagatedType\n\n" : ''}
$apiLink\n\n''';

    var htmlDocs = markdown.markdownToHtml(mdDocs,
        inlineSyntaxes: [InlineBracketsColon(), InlineBrackets()]);

    // Append a 'launch' icon to the 'Open library docs' link.
    htmlDocs = htmlDocs.replaceAll('library docs</a>',
        "library docs <span class='launch-icon'></span></a>");

    return _DocResult(htmlDocs, kind?.replaceAll(' ', '_'));
  }

  String _dartApiLink(String? libraryName) {
    if (libraryName == null ||
        libraryName.isEmpty ||
        libraryName == 'main.dart') {
      return '';
    }

    final usingFlutter = hasFlutterContent(_sourceProvider.dartSource);
    final isDartLibrary = libraryName.contains('dart:');

    // Only can link to library docs for dart libraries or `package:flutter`.
    if (isDartLibrary || usingFlutter) {
      if (usingFlutter) {
        final splitFlutter = libraryName.split('/');

        if (splitFlutter[0] == 'package:flutter') {
          splitFlutter.removeAt(0);
          // Find library name, either after package declaration or `src`.
          libraryName = splitFlutter
              .firstWhere((element) => element != 'src')
              .replaceAll('.dart', '');
        } else if (!isDartLibrary) {
          // If it's not a Flutter or Dart library, return just the name.
          return libraryName;
        }
      }

      final apiLink = StringBuffer('[Open library docs](');

      if (usingFlutter) {
        apiLink.write('https://api.flutter.dev/flutter');
      } else {
        apiLink.write('https://api.dart.dev/stable');
      }

      libraryName = libraryName.replaceAll(':', '-');
      apiLink.write('/$libraryName/$libraryName-library.html)');

      return apiLink.toString();
    }

    return libraryName;
  }
}

class _DocResult {
  final String html;
  final String? entityKind;

  _DocResult(this.html, [this.entityKind]);
}

class InlineBracketsColon extends markdown.InlineSyntax {
  InlineBracketsColon() : super(r'\[:\s?((?:.|\n)*?)\s?:\]');

  String htmlEscape(String text) => convert.htmlEscape.convert(text);

  @override
  bool onMatch(markdown.InlineParser parser, Match match) {
    final element = markdown.Element.text('code', htmlEscape(match[1]!));
    parser.addNode(element);
    return true;
  }
}

// TODO: [someCodeReference] should be converted to for example
// https://api.dartlang.org/apidocs/channels/stable/dartdoc-viewer/dart:core.someReference
// for now it gets converted <code>someCodeReference</code>
class InlineBrackets extends markdown.InlineSyntax {
  // This matches URL text in the documentation, with a negative filter
  // to detect if it is followed by a URL to prevent e.g.
  // [text] (http://www.example.com) getting turned into
  // <code>text</code> (http://www.example.com)
  InlineBrackets() : super(r'\[\s?((?:.|\n)*?)\s?\](?!\s?\()');

  String htmlEscape(String text) => convert.htmlEscape.convert(text);

  @override
  bool onMatch(markdown.InlineParser parser, Match match) {
    final element =
        markdown.Element.text('code', '<em>${htmlEscape(match[1]!)}</em>');
    parser.addNode(element);
    return true;
  }
}
