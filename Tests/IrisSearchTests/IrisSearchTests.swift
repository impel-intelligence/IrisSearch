import Testing
@testable import IrisSearch
import NaturalLanguage

@Test func wordTokenization() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    let testText = """
        Hello, this is a reasonable test of the tokenization provided by the NaturalLanguage package. I am not sure how this will work, especially with contractions like: aren't, can't, won't.
        """
    
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = testText
    let stringRange = testText.startIndex..<testText.endIndex
    let tokens = tokenizer.tokens(for: stringRange)
    
    for range in tokens {
        print(testText[range])
    }
}
