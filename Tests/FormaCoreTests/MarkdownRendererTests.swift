import Testing
@testable import FormaCore

@Suite("Markdown renderer")
struct MarkdownRendererTests {
    let r = MarkdownRenderer()

    @Test func headings() {
        #expect(r.renderBody("# Title") == "<h1 id=\"title\">Title</h1>")
        #expect(r.renderBody("### Third ###") == "<h3 id=\"third\">Third</h3>")
        #expect(r.renderBody("Setext\n===") == "<h1 id=\"setext\">Setext</h1>")
        #expect(r.renderBody("#NoSpace") == "<p>#NoSpace</p>")
    }

    @Test func emphasis() {
        #expect(r.renderInline("**bold** and *it*") == "<strong>bold</strong> and <em>it</em>")
        #expect(r.renderInline("***both***") == "<strong><em>both</em></strong>")
        #expect(r.renderInline("snake_case_name") == "snake_case_name")
        #expect(r.renderInline("~~gone~~") == "<del>gone</del>")
        #expect(r.renderInline("2 * 3 * 4") == "2 * 3 * 4")
        #expect(r.renderInline("**unclosed") == "**unclosed")
    }

    @Test func codeIsEscaped() {
        #expect(r.renderInline("`<b>`") == "<code>&lt;b&gt;</code>")
        #expect(r.renderBody("```swift\nlet a = 1 < 2\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>")
        #expect(r.renderBody("    indented") == "<pre><code>indented</code></pre>")
    }

    @Test func rawHTMLAndScriptURLsAreNeutralised() {
        #expect(r.renderBody("<script>alert(1)</script>") == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        #expect(r.renderInline("[x](javascript:alert(1))") == "<a href=\"#\">x</a>")
    }

    @Test func linksAndImages() {
        #expect(r.renderInline("[Apple](https://apple.com \"Home\")") == "<a href=\"https://apple.com\" title=\"Home\">Apple</a>")
        #expect(r.renderInline("![alt text](pic.png)") == "<img src=\"pic.png\" alt=\"alt text\">")
        #expect(r.renderInline("see <https://example.com>") == "see <a href=\"https://example.com\">https://example.com</a>")
        #expect(r.renderInline("visit https://example.com.") == "visit <a href=\"https://example.com\">https://example.com</a>.")
    }

    @Test func lists() {
        #expect(r.renderBody("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        #expect(r.renderBody("3. c\n4. d") == "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>")
        let nested = r.renderBody("- a\n  - b\n- c")
        #expect(nested == "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul></li>\n<li>c</li>\n</ul>")
        #expect(r.renderBody("- [x] done\n- [ ] todo").contains("<input type=\"checkbox\" checked disabled> done"))
        #expect(r.renderBody("- a\n\n- b").contains("<li><p>a</p></li>"), "loose lists wrap items in paragraphs")
    }

    @Test func blockquotesAndRules() {
        #expect(r.renderBody("> quoted\n> more") == "<blockquote>\n<p>quoted\nmore</p>\n</blockquote>")
        #expect(r.renderBody("---") == "<hr>")
        #expect(r.renderBody("* * *") == "<hr>")
    }

    @Test func tables() {
        let html = r.renderBody("| a | b |\n|:--|--:|\n| 1 | `x|y` |")
        #expect(html.contains("<th style=\"text-align: left\">a</th><th style=\"text-align: right\">b</th>"))
        #expect(html.contains("<td style=\"text-align: right\"><code>x|y</code></td>"))
    }

    @Test func hardBreaksAndEscapes() {
        #expect(r.renderInline("line  \nnext") == "line<br>\nnext")
        #expect(r.renderInline("\\*not em\\*") == "*not em*")
        #expect(r.renderInline("a & b") == "a &amp; b")
    }
}
