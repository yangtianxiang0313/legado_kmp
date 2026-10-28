import shared

struct BookDetailPreviewSeed {
    let name: String
    let author: String?
    let kind: String?
    let intro: String?
    let coverCandidate: SearchBook
    let originName: String?

    init(searchBook: SearchBook) {
        name = searchBook.name
        author = searchBook.author
        kind = searchBook.kind
        intro = searchBook.intro
        coverCandidate = searchBook
        originName = searchBook.originName
    }
}
