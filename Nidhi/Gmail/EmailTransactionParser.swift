import Foundation

/// Parses Indian bank/credit-card transaction-alert emails into transactions.
///
/// Patterns are derived from a survey of this mailbox's **real** alert mail (2018 – 2026) across
/// HDFC, Federal/Scapia, ICICI and Axis — including the retired wordings each bank has cycled
/// through, because backfilling old mail depends on them. Every bank re-words its alerts every
/// year or two and keeps the same subject line, so patterns are matched on the *body*, ordered
/// most-specific-first, and grouped per issuer.
///
/// **Contract:** `parse` returns a transaction only for mail stating a *completed* money movement.
/// OTPs, declines, pre-debit intimations, mandate registrations, statement notices and service
/// mail all quote an amount, a merchant and a card number, so they would otherwise book phantom
/// transactions — `isNonTransactional` rejects them before any positive pattern runs.
///
/// Deliberately **not** parsed (documented in docs/integrations.md):
/// - Prepaid-wallet spends (ICICI FASTag tolls, HDFC Foodplus): the money already left a tracked
///   account when the wallet was loaded, so booking the spend too would double-count it.
/// - BillDesk "bill payment processed" mail: the same payment already arrives as the HDFC
///   standing-instruction debit on the funding account.
/// - ICICI standing-instruction receipts: the plain card transaction alert fires seconds earlier
///   for the same charge.
/// - Foreign-currency card alerts: they state only the foreign amount, never the INR value, so the
///   card statement is the only correct source.
enum EmailTransactionParser {

    struct Source { var id: String; var sender: String; var subject: String; var dateHeader: String; var body: String }

    // MARK: - Shared regex fragments
    /// Every currency prefix seen in the wild: `Rs.20.00`, `Rs 123.45`, `INR 1,23,456.78`,
    /// `₹2,120.46`, `INR.199.00` (period glued on), and HDFC's doubled `Rs. INR 1,23,456.78`.
    private static let cur = #"(?:Rs\.?\s*)?(?:INR|Rs|₹)\.?\s*"#
    /// Amount body. Indian grouping is optional because Gmail's own text extraction sometimes
    /// drops a comma from the same mail the HTML renders as `7,43,983.38`.
    private static let amt = #"([\d,]+(?:\.\d{1,2})?)"#
    /// Account / card masks: `4068`, `XX4068`, `**4068`, `xxxxxxxxxx4068`, `4315 XXXX XXXX 4068`.
    /// The leading repeat swallows space-separated card groups (ICICI prints the full PAN that way)
    /// so the capture is always the trailing last-4, never the issuer BIN.
    private static let msk = #"(?:[\dXx*]{4}[\s-]*){0,3}[Xx*]*(\d{3,})"#

    static func parse(_ src: Source) -> SyncedTxn? {
        // Only known bank alert senders may mint a transaction. The Gmail query also matches on
        // content keywords ("has been debited"), so without this gate any newsletter quoting that
        // phrase could book money.
        guard let bank = bankCode(fromSender: src.sender) else { return nil }
        let text = htmlToText(src.body)
        guard !isNonTransactional(text, subject: src.subject) else { return nil }
        let headerDate = rfcDate(src.dateHeader)

        switch bank {
        case "HDFC":  return parseHDFC(src, text, headerDate)
        case "FED":   return parseFederal(src, text, headerDate)
        case "ICICI": return parseICICI(src, text, headerDate)
        case "AXIS":  return parseAxis(src, text, headerDate)
        default:      return parseGenericBank(src, text, headerDate, bank: bank)
        }
    }

    // MARK: - Sender gate
    /// Alert-sender → bank code. Banks migrated to `<bank>.bank.in` domains through 2025-26 while
    /// keeping the old ones alive, so both spellings must map. Note `axisbank` does **not** match
    /// `alerts@axis.bank.in` — that gap silently dropped every Axis alert of 2026.
    static func bankCode(fromSender sender: String) -> String? {
        let s = sender.lowercased()
        guard !isPromoSender(s) else { return nil }
        if s.contains("hdfcbank") { return "HDFC" }
        if s.contains("federalbank") || s.contains("federal.bank.in") || s.contains("scapia") { return "FED" }
        if s.contains("axisbank") || s.contains("axis.bank.in") { return "AXIS" }
        if s.contains("icicibank") { return "ICICI" }
        if s.contains("kotak") { return "KOTAK" }
        if s.contains("@sbi.") || s.contains("sbicard") { return "SBI" }
        return nil
    }

    /// Senders on an issuer's own domain that never carry an alert: marketing sub-domains, and —
    /// more dangerously — support mailboxes. A reply from `customer.service@axisbank.com` quotes the
    /// customer's original alert verbatim underneath the agent's text, so without this the quoted
    /// alert books the same spend a second time.
    private static func isPromoSender(_ s: String) -> Bool {
        ["information@", "mailers.", "customercomm", "custcomm", "scapia_info", "scapia.info",
         "scapia_updates", "scapia.alerts", "scapia_emioffers", "scapia.events",
         "go.federalbank", "digital.axisbankmail", "@mailers.",
         "customer.service@", "customercare@", "donotreply@", "noreply@", "no-reply@",
         "secure.services@", "account_services@", "termloans.", "emailstatements.",
         "smartstatement@", "cc.statements@", "prepaidcards@", "straight2axis@"].contains { s.contains($0) }
    }

    // MARK: - Negative guards
    /// Mail that quotes money but moves none. Checked before every positive pattern.
    static func isNonTransactional(_ text: String, subject: String) -> Bool {
        let t = text.lowercased(), s = subject.lowercased()
        // Several markers only ever appear in the *subject* (e.g. "Pre-debit notification on Axis
        // Bank Card", whose body says "will be auto debited"), so the intimation and mandate groups
        // below are tested against subject+body together.
        let h = t + " " + s

        // OTPs — quote amount, merchant and card, and are the highest-volume near-miss.
        if ["is the otp", "otp is ", "otp for ", "one time password", "do not share this otp",
            "is your otp", "otp to complete"].contains(where: { t.contains($0) }) { return true }
        if s.contains("otp") || s.contains("one time password") { return true }

        // Declines / failures — money did NOT move.
        if ["was declined", "has declined", "has been declined", "is declined", "payment declined",
            "declined!", "could not be completed", "payment unsuccessful", "payment failed",
            "transaction failed", "declined due to", "insufficient balance"].contains(where: { t.contains($0) }) { return true }
        if s.contains("unsuccessful") || s.contains("declined") { return true }

        // Future-tense intimations: pre-debit notices, mandate reminders, instalment due dates.
        // The real debit arrives later in its own mail; booking both double-counts.
        if ["will be deducted", "will be debited", "will be auto debited", "will be presented",
            "to be debited by", "is due on", "bill is due", "payment is due",
            "upcoming e-mandate", "upcoming payment", "upcoming autopay", "autopay txn. reminder",
            "pre-debit notification", "amount will be debited", "please ensure sufficient balance"]
            .contains(where: { h.contains($0) }) { return true }

        // Mandate lifecycle (registration / tokenisation / activation) — no money moves.
        if ["successfully registered the standing instruction", "registered for e-mandate",
            "registered successfully", "replaced with a token", "token update",
            "auto pay facility has been activated", "auto pay activation is successful",
            "successful registration"]
            .contains(where: { h.contains($0) }) { return true }

        // Statement-ready notices and EMI amortisation schedules.
        if s.contains("statement") || s.contains("amortization") || s.contains("amortisation") { return true }
        if ["into equated monthly instalments", "amortisation/repayment schedule",
            "e-statement is attached", "statement of account for"].contains(where: { t.contains($0) }) { return true }

        // Service notices that carry an account number but no movement.
        if ["has been dispatched", "on its way to your", "addition of the payee",
            "addition/modification of the payee", "classified as inoperative",
            "nominee has been updated", "has not been used for over",
            "accessing your locker"].contains(where: { t.contains($0) }) { return true }

        // Already-counted duplicates (see the type doc for why each is excluded).
        if t.contains("via on billpay") || t.contains("processed successfully via billpay") { return true }
        if t.contains("with standing instruction") && t.contains("successfully processed your payment") { return true }
        if t.contains("fastag linked to vehicle") { return true }
        if t.contains("foodplus card") { return true }

        return false
    }

    // MARK: - HDFC Bank
    private static func parseHDFC(_ src: Source, _ text: String, _ headerDate: Date) -> SyncedTxn? {
        // ── Savings/current account ──

        // UPI debit, current wording: "Rs.20.00 is debited from your account ending 4068 towards
        // VPA someone@okhdfcbank (PAYEE NAME) on 28-07-26."
        if let g = cap(cur + amt + #"\s*(?:is|has been)\s+debited\s+from\s+(?:your\s+)?account\s+(?:ending\s+)?"# + msk
                       + #"\s*(?:towards|to)\s+VPA\s+(\S+?)\s*(?:\(([^)]+)\))?\s+on\s+(\d{2}-\d{2}-\d{2,4})"#, text, 5) {
            let name = g[4].isEmpty ? vpaName(after: g[3], in: text) : g[4]
            let m = name.isEmpty ? g[3] : clean(name)
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "UPI \(g[3]) \(name)", date: date(g[5]) ?? headerDate)
        }
        // UPI credit, one-sentence wording (2024 → mid-2026):
        // "Rs. 123.45 is successfully credited to your account **4068 by VPA x@okaxis NAME on 06-05-26."
        if let g = cap(cur + amt + #"\s*(?:is|has been)\s+successfully\s+credited\s+to\s+your\s+account\s+"# + msk
                       + #"\s*by\s+VPA\s+(\S+)\s*([A-Za-z .]*?)\s+on\s+(\d{2}-\d{2}-\d{2,4})"#, text, 5) {
            let m = g[4].trimmingCharacters(in: .whitespaces).isEmpty ? g[3] : clean(g[4])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "UPI credit \(g[3]) \(g[4])", date: date(g[5]) ?? headerDate)
        }
        // UPI credit, current labelled wording: "...successfully credited to your HDFC Bank account
        // ending in 4068. Transaction Details: a. Date: 29-07-26 b. Sender: NAME (VPA: x@y) c. ..."
        if let g = cap(cur + amt + #"\s*has been successfully credited to your HDFC Bank account ending in\s+"# + msk
                       + #"[\s\S]{0,80}?Date:\s*(\d{2}-\d{2}-\d{2,4})\s*b\.\s*Sender:\s*(.+?)\s*(?:\(VPA:\s*(\S+?)\))?\s*c\."#, text, 5) {
            let m = clean(g[4])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "UPI credit \(g[4]) \(g[5])", date: date(g[3]) ?? headerDate)
        }
        // UPI debit, legacy: "Rs.X has been debited from account **4068 to VPA x@oksbi NAME on 31-12-25."
        if let g = cap(cur + amt + #"\s*has been debited from account\s+"# + msk
                       + #"\s*to\s+(?:VPA|account)\s+(\S+)\s*([A-Za-z .]*?)\s+on\s+(\d{2}-\d{2}-\d{2,4})"#, text, 5) {
            let m = g[4].trimmingCharacters(in: .whitespaces).isEmpty ? g[3] : clean(g[4])
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "UPI \(g[3]) \(g[4])", date: date(g[5]) ?? headerDate)
        }

        // Standing-instruction / auto-debit deduction — the single most important account format:
        // loan EMIs, credit-card autopay (own and other banks) and RD instalments all arrive here.
        // "Rs. INR 26,191.00 is deducted from your account ending XX4068 and added to
        //  EMI 151315644 Chq S... account on 07-JUN-2026."
        if let g = cap(cur + amt + #"\s*is deducted from your account ending\s+"# + msk
                       + #"\s*and added to\s+(.+?)\s+account\s+on\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})"#, text, 4) {
            let m = siMerchant(g[3])
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: g[3], date: date(g[4]) ?? headerDate)
        }

        // Deposit alert, current labelled wording — this is how salary credits arrive.
        // "Amount received: INR 1,23,456.78  Account: XX4068  Date: 12-JUN-2026
        //  Reference Details: NEFT Cr-<IFSC>-<EMPLOYER>-<BENEFICIARY>-<REF>"
        if let g = cap(#"Amount received:\s*"# + cur + amt + #"\s*Account:\s*"# + msk
                       + #"\s*Date:\s*(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})\s*Reference Details:\s*(.+?)\s*(?:Available Balance|For real-time|Thank you|$)"#, text, 4) {
            let m = siMerchant(g[4])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m.isEmpty ? "Deposit" : m, narration: g[4], date: date(g[3]) ?? headerDate)
        }
        // Deposit alert, 2024-2025 wording: "The amount credited/received is INR X in your account
        // XX4068 on 28-FEB-2025 on account of <narration>"
        if let g = cap(#"amount credited/received is\s*"# + cur + amt + #"\s*in your account\s+"# + msk
                       + #"\s*on\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})\s*on account of\s+(.+?)\s*(?:Your A/c is at|Your Available|If you have|$)"#, text, 4) {
            let m = siMerchant(g[4])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m.isEmpty ? "Deposit" : m, narration: g[4], date: date(g[3]) ?? headerDate)
        }
        // Salary alert, oldest wording: "Your Salary of INR X has been credited to A/c XX4068 at
        // <BRANCH> on account of <narration> on 31-AUG-2021."
        if let g = cap(#"Your Salary of\s*"# + cur + amt + #"\s*has been credited to A/c\s*"# + msk
                       + #"\s*(?:at\s+.+?)?\s*on account of\s+(.+?)\s+on\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})"#, text, 4) {
            let m = railMerchant(g[3])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .bank, bankCode: "HDFC",
                        counterparty: m.isEmpty ? "Salary" : m, merchant: m.isEmpty ? "Salary" : m,
                        narration: "Salary \(g[3])", date: date(g[4]) ?? headerDate)
        }

        // IMPS out, current: "INR 30,000.00 has been debited from your account ending xxxxxxxxxx4068
        // on 28-07-26 and credited to the account ending xxxxxxxxxx0645 via IMPS."
        if let g = cap(cur + amt + #"\s*has been debited from your account ending\s+"# + msk
                       + #"\s*on\s+(\d{2}-\d{2}-\d{2,4})\s*and credited to the account ending\s+"# + msk
                       + #"\s*via\s+(\w+)"#, text, 5) {
            let m = "Transfer to ••\(g[4])"
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "\(g[5]) transfer to a/c ending \(g[4])",
                        date: date(g[3]) ?? headerDate)
        }
        // IMPS out, legacy: "Your A/c xxxxxxxxxx4068 is debited for INR 1234.00 on 02-11-25 and
        // A/c xxxxxxxx0645 is credited."
        if let g = cap(#"Your A/c\s+"# + msk + #"\s*is debited for\s*"# + cur + amt
                       + #"\s*on\s+(\d{2}-\d{2}-\d{2,4})\s*and A/c\s+"# + msk + #"\s*is credited"#, text, 5) {
            let m = "Transfer to ••\(g[4])"
            return make(src, mask: g[1], amount: g[2], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "IMPS transfer to a/c ending \(g[4])",
                        date: date(g[3]) ?? headerDate)
        }

        // NetBanking transfer to a saved payee (NEFT or intra-bank). No date in the body — the mail
        // is sent at the time of the transfer, so the header date is the transaction date.
        if let g = cap(cur + amt + #"\s*(?:has been\s+)?deducted from your (?:HDFC Bank )?[Aa]ccount(?:\s+No\.?)?\s*(?:ending\s+in\s+)?"# + msk
        // The payee slot is a user-typed nickname, so the trailing rail word must be preceded by real
        // whitespace — with `\s*` the lazy capture stops at the "via"/"using" *inside* a name like
        // "HOUSING SOCIETY" or "Olivia HDFC", truncating the merchant to two letters.
                       + #"\s*for\s+(?:a\s+)?(?:[Tt]ransfer to payee\s+(.+?)|Money Transfer|Credit Card Payment|(\w+) transaction)\s+(?:via|using|done\s+using)\b"#, text, 4) {
            let payee = !g[3].isEmpty ? clean(g[3])
                : (text.lowercased().contains("credit card payment") ? "Credit card payment" : "Bank transfer")
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: payee, merchant: payee, narration: "Online banking transfer \(g[3])",
                        date: headerDate)
        }
        // Credit-card bill paid from the account via NetBanking (2024 wording).
        if let g = cap(#"an amount of\s*"# + cur + amt + #"\s*has been debited from your Account number\s+"# + msk
                       + #"\s*for\s+Credit Card Payment"#, text, 3) {
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: "Credit card payment", merchant: "Credit card payment",
                        narration: "Credit card payment via NetBanking", date: headerDate)
        }
        // NEFT out, stacked telegraphic wording: "Amount deducted Of Rs. 50000 From your HDFC Bank
        // A/c XX4068 For NEFT transaction Via HDFC Bank Online Banking."
        if let g = cap(#"Amount deducted\s+Of\s*"# + cur + amt + #"\s*From your HDFC Bank A/c\s*"# + msk
                       + #"\s*For\s+(\w+)\s+transaction"#, text, 3) {
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: "\(g[3]) transfer", merchant: "\(g[3]) transfer",
                        narration: "\(g[3]) transfer via online banking", date: headerDate)
        }
        // NetBanking payment to a biller/merchant, labelled block (mid-2026):
        // "Payment Details Amount: Rs. 200000.00 From Account: **********4068 Paid To: <PAYEE>"
        if let g = cap(#"Amount:\s*"# + cur + amt + #"\s*From Account:\s*"# + msk + #"\s*Paid To:\s*([A-Za-z0-9 .&*_-]{2,40}?)\s*(?:Important|Not You|Need Help|$)"#, text, 4) {
            let m = clean(g[3])
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "NetBanking payment to \(g[3])", date: headerDate)
        }
        // NetBanking payment to a biller/merchant, one-line predecessor:
        // "...NetBanking for payment of Rs. 200000.00 from A/c XX4068 to PAYTMPAYTMMONEYMUTUA"
        if let g = cap(#"NetBanking for payment of\s*"# + cur + amt + #"\s*from A/c\s*"# + msk
                       + #"\s*to\s+([A-Za-z0-9 .&*_-]{2,40}?)\s*(?:As a thank|Not you|For any queries|Warm Regards|$)"#, text, 4) {
            let m = clean(g[3])
            return make(src, mask: g[2], amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "NetBanking payment to \(g[3])", date: headerDate)
        }

        // ── Debit card (spends the savings account; mask is the CARD's last-4, so the account is
        //    resolved by bank code instead — see Store.resolveAccountName) ──
        if let g = cap(cur + amt + #"\s*is debited from your HDFC Bank Debit Card ending\s+"# + msk
                       + #"\s*at\s+(.+?)\s+on\s+(\d{1,2}\s+\w{3},?\s+\d{4})"#, text, 4) {
            let m = clean(g[3])
            return make(src, mask: "", amount: g[1], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "Debit card ••\(g[2]) · \(g[3])",
                        date: date(g[4]) ?? headerDate)
        }
        if let g = cap(#"using your HDFC Bank Debit Card ending\s+"# + msk + #"\s*for ATM withdrawal for\s*"# + cur + amt
                       + #"\s*(?:in\s+(.+?)\s+)?at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{4})"#, text, 5) {
            let m = "ATM withdrawal"
            return make(src, mask: "", amount: g[2], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "ATM ••\(g[1]) · \(g[4]) \(g[3])",
                        date: date(g[5]) ?? headerDate)
        }
        if let g = cap(#"using your HDFC Bank Debit Card ending\s+"# + msk + #"\s*for\s*"# + cur + amt
                       + #"\s*at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{4})"#, text, 4) {
            let m = clean(g[3])
            return make(src, mask: "", amount: g[2], credit: false, source: .bank, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "Debit card ••\(g[1]) · \(g[3])",
                        date: date(g[4]) ?? headerDate)
        }

        // ── Credit card ──
        if let g = cap(cur + amt + #"\s*has been\s+(debited|credited)\s+(?:from|to)\s+your HDFC Bank Credit Card ending\s+"# + msk
                       + #"\s*towards\s+(.+?)\s+on\s+(\d{1,2}\s+\w{3},?\s+\d{4})"#, text, 5) {
            let credit = g[2].lowercased() == "credited"
            let m = clean(g[4])
            return make(src, mask: g[3], amount: g[1], credit: credit, source: .card, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "HDFC Credit Card · \(g[4])",
                        date: date(g[5]) ?? headerDate)
        }
        // Card refund: "A transaction reversal of Rs. X has been initiated to your HDFC Bank Credit
        // Card ending 3427 From Merchant: ZIPPYMART Date  Time: 25 Jul, 2026 at 18:01:24"
        if let g = cap(#"transaction reversal of\s*"# + cur + amt + #"\s*has been initiated to your HDFC Bank Credit Card ending\s+"# + msk
                       + #"\s*From Merchant:\s*(.+?)\s*Date\s*Time:\s*(\d{1,2}\s+\w{3},?\s+\d{4})"#, text, 4) {
            let m = clean(g[3])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .card, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "HDFC Credit Card refund · \(g[3])",
                        date: date(g[4]) ?? headerDate)
        }
        // E-mandate charge PAID on the card: "Your NETFLIX bill set on e-Mandate is paid through
        // your HDFC Bank Credit Card. Current Txn Amt: INR.199.00 Date:28/02/2025"
        if let g = cap(#"Your\s+(.+?)\s+bill set on e-Mandate is paid through your HDFC Bank Credit Card\.?\s*Current Txn Amt:\s*"#
                       + cur + amt + #"\s*Date:\s*(\d{2}/\d{2}/\d{4})"#, text, 3) {
            let m = clean(g[1])
            return make(src, mask: "", amount: g[2], credit: false, source: .card, bankCode: "HDFC",
                        counterparty: m, merchant: m, narration: "e-Mandate · \(g[1])", date: date(g[3]) ?? headerDate)
        }

        return nil
    }

    // MARK: - Federal Bank / Scapia
    private static func parseFederal(_ src: Source, _ text: String, _ headerDate: Date) -> SyncedTxn? {
        // Scapia card spend. Two wordings share one shape: the plain "Your payment on <date> at
        // <time> using your Scapia Federal <network> Credit Card ending in N has been successfully
        // processed", and the rewards variant "You've earned N rewards for your transaction|payment
        // on <date> at <time> using your …". Amount and merchant follow as label rows.
        if let g = cap(#"(?:You\S{0,2}ve earned\s+(\d+)\s+rewards? for your (?:transaction|payment)|Your payment)\s+on\s+(\d{2}-\d{2}-\d{4})\s+at\s+[\d:]+\s*(?:AM|PM)?\s*using your Scapia Federal[^.]*?Credit Card ending in\s+"#
                       + msk + #"[\s\S]*?Amount\s*"# + cur + amt + #"\s*Merchant\s+(.{2,60}?)\s*(?:Not you|Need help|What\S{0,2}s more|Convert to EMI|$)"#, text, 5) {
            let m = boundMerchant(g[5])
            var t = make(src, mask: g[3], amount: g[4], credit: false, source: .card, bankCode: "FED",
                         counterparty: m, merchant: m, narration: "Scapia Federal CC · \(m)",
                         date: date(g[2]) ?? headerDate)
            if let r = Double(g[1]) { t?.reward = r; t?.rewardCurrency = "rewards" }
            return t
        }
        // Fuel-surcharge waiver / other card credits stated inline.
        if let g = cap(#"(?:A fuel surcharge waiver|An amount) of\s*"# + cur + amt
                       + #"\s*has been credited to your Scapia Federal[^.]*?Credit Card ending in\s+"# + msk
                       + #"\s*on\s+(\d{2}-\d{2}-\d{4})"#, text, 3) {
            let m = text.lowercased().contains("fuel surcharge") ? "Fuel surcharge waiver" : "Card credit"
            return make(src, mask: g[2], amount: g[1], credit: true, source: .card, bankCode: "FED",
                        counterparty: m, merchant: m, narration: "Scapia Federal Credit Card", date: date(g[3]) ?? headerDate)
        }
        // Merchant refund: card + amount + merchant, no original-transaction date in the body.
        if let g = cap(#"received a refund on your Scapia Federal[^.]*?Credit Card ending in\s+"# + msk
                       + #"[\s\S]*?Amount\s*"# + cur + amt + #"\s*Merchant\s+(.{2,60}?)\s*(?:Not you|Need help|$)"#, text, 3) {
            let m = boundMerchant(g[3])
            return make(src, mask: g[1], amount: g[2], credit: true, source: .card, bankCode: "FED",
                        counterparty: m, merchant: m, narration: "Scapia Federal CC refund · \(m)", date: headerDate)
        }
        // Card bill repayment received — a transfer, not income (Classifier flags it via wording).
        if let g = cap(#"received your payment of\s*"# + cur + amt + #"\s*towards your Scapia Federal"#, text, 1) {
            let m = "Credit card payment received"
            return make(src, mask: "", amount: g[1], credit: true, source: .card, bankCode: "FED",
                        counterparty: m, merchant: m, narration: "Scapia Federal card bill payment", date: headerDate)
        }
        return nil
    }

    // MARK: - ICICI Bank
    private static func parseICICI(_ src: Source, _ text: String, _ headerDate: Date) -> SyncedTxn? {
        // Card spend — one shape across three eras. The date is "Apr 10, 2026 at 10:40:13" (current)
        // or "December 01, 2022; 01:52:29" (2022); whitespace is already collapsed by htmlToText.
        if let g = cap(#"ICICI Bank Credit Card\s*"# + msk + #"\s*has been used for a transaction of\s*"# + cur + amt
        // `Info:` merchants contain internal periods ("IND*Amazon.in - Grocer"), so the terminator is
        // a period followed by whitespace/end — a bare `\.` truncates them at the first dot.
                       + #"\s*on\s+([A-Za-z]{3,9}\s+\d{1,2},\s*\d{4})[;\s]*(?:at\s*)?[\d:]{4,8}\s*\.?\s*Info:\s*(.+?)\s*\.(?=\s|$)"#, text, 4) {
            let m = clean(g[4].replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespaces))
            return make(src, mask: g[1], amount: g[2], credit: false, source: .card, bankCode: "ICICI",
                        counterparty: m, merchant: m, narration: "ICICI Credit Card · \(m)", date: date(g[3]) ?? headerDate)
        }
        // Bill payment received (2024 → current): "We have received payment of INR X on your ICICI
        // Bank Credit Card account 4315 XXXX XXXX 8019 on 30-Mar-2026."
        if let g = cap(#"received payment of\s*"# + cur + amt + #"\s*on your ICICI Bank Credit Card account\s*"# + msk
                       + #"\s*on\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})"#, text, 3) {
            let m = "Credit card payment received"
            return make(src, mask: g[2], amount: g[1], credit: true, source: .card, bankCode: "ICICI",
                        counterparty: m, merchant: m, narration: "ICICI Credit Card bill payment", date: date(g[3]) ?? headerDate)
        }
        // Bill payment received (2020-2024): "Payment of INR X towards ICICI Bank Credit Card XX8019
        // has been received through UPI on November 30, 2023."
        if let g = cap(#"Payment of\s*"# + cur + amt + #"\s*towards ICICI Bank Credit Card\s*"# + msk
                       + #"\s*has been received(?:\s+through\s+(\w+))?\s*on\s+([A-Za-z]{3,9}\s+\d{1,2},\s*\d{4})"#, text, 4) {
            let m = "Credit card payment received"
            return make(src, mask: g[2], amount: g[1], credit: true, source: .card, bankCode: "ICICI",
                        counterparty: m, merchant: m, narration: "ICICI Credit Card bill payment \(g[3])",
                        date: date(g[4]) ?? headerDate)
        }
        // Merchant refund: "...merchant credit refund on your ICICI Bank Credit Card XX8019 for
        // INR X on April 27, 2023 from CLOUDHOST SERVICES."
        if let g = cap(#"merchant credit refund on your ICICI Bank Credit Card\s*"# + msk + #"\s*for\s*"# + cur + amt
                       + #"\s*on\s+([A-Za-z]{3,9}\s+\d{1,2},\s*\d{4})\s*from\s+(.+?)\s*\."#, text, 4) {
            let m = clean(g[4])
            return make(src, mask: g[1], amount: g[2], credit: true, source: .card, bankCode: "ICICI",
                        counterparty: m, merchant: m, narration: "ICICI Credit Card refund · \(g[4])",
                        date: date(g[3]) ?? headerDate)
        }
        return nil
    }

    // MARK: - Axis Bank
    private static func parseAxis(_ src: Source, _ text: String, _ headerDate: Date) -> SyncedTxn? {
        let reversed = text.lowercased().contains("reversed") || text.lowercased().contains("reversal")

        // Current labelled format (2025 →): "Transaction Amount: INR X Merchant Name: NAME
        // Axis Bank Credit Card No. XX1990 Date & Time: 21-07-2026, 15:12:51 IST"
        if let g = cap(#"Transaction Amount:\s*(?:INR|Rs\.?|₹)\s*"# + amt + #"\s*Merchant Name:\s*(.+?)\s*Axis Bank Credit Card No\.?\s*"#
                       + msk, text, 3) {
            let m = clean(g[2])
            let d = cap(#"Date\s*&\s*Time:\s*(\d{2}[-/]\d{2}[-/]\d{2,4})"#, text, 1).flatMap { date($0[1]) }
            // The narration must say "reversal": `Store.classify` decides refund-vs-income purely on
            // free text, so a credit with a plain narration is booked as Income.
            return make(src, mask: g[3], amount: g[1], credit: reversed, source: .card, bankCode: "AXIS",
                        counterparty: m, merchant: m,
                        narration: "Axis Credit Card \(reversed ? "reversal " : "")· \(g[2])", date: d ?? headerDate)
        }
        // Prose reversal (2024 – mid-2025): "...the transaction of INR 123.45 on Axis Bank Credit
        // Card no. XX1990 on 12-03-25 14:04:18 IST at SOME MERCHA has been reversed."
        if let g = cap(#"transaction of\s*(?:INR|Rs\.?|₹)\s*"# + amt + #"\s*on Axis Bank Credit Card no\.?\s*"# + msk
                       + #"\s*on\s+(\d{2}-\d{2}-\d{2,4})\s*[\d:]*\s*(?:IST)?\s*at\s+(.+?)\s+has been reversed"#, text, 4) {
            let m = clean(g[4])
            return make(src, mask: g[2], amount: g[1], credit: true, source: .card, bankCode: "AXIS",
                        counterparty: m, merchant: m, narration: "Axis Credit Card reversal · \(g[4])",
                        date: date(g[3]) ?? headerDate)
        }
        // Prose spend, all three eras: "Thank you for using your [Axis Bank] [credit] [Cc]ard no.
        // XX1990 for INR 123.45 at MERCHANT on 19-05-2025 18:12:54 [IST]."
        // Non-INR spends are skipped on purpose: the mail never states the INR value, so only the
        // card statement can supply it.
        if let g = cap(#"Thank you for using your\s+(?:Axis Bank\s+)?(?:[Cc]redit\s+)?[Cc]ard no\.?\s*"# + msk
                       + #"\s*for\s+([A-Z]{3})\s*"# + amt + #"\s*at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{2,4})"#, text, 5) {
            guard g[2] == "INR" else { return nil }
            let m = clean(g[4])
            return make(src, mask: g[1], amount: g[3], credit: reversed, source: .card, bankCode: "AXIS",
                        counterparty: m, merchant: m,
                        narration: "Axis Credit Card \(reversed ? "reversal " : "")· \(g[4])",
                        date: date(g[5]) ?? headerDate)
        }
        return nil
    }

    // MARK: - Generic fallback (banks with no issuer-specific pattern yet)
    /// Last resort for a known bank sender whose wording we have not surveyed. Deliberately narrow:
    /// completed-tense verbs only, an account mask, and a rail narration to name the counterparty.
    private static func parseGenericBank(_ src: Source, _ text: String, _ headerDate: Date, bank: String) -> SyncedTxn? {
        if let g = cap(cur + amt + #"\s+(?:is|has been|was)\s+(?:successfully\s+)?(debited|credited|deducted)\s+(?:from|to|into|in)\s+your\s+(?:\w+\s+){0,2}?a(?:/c|ccount)\s*(?:no\.?|number|ending)?\s*(?:in\s+)?[.:]?\s*"# + msk, text, 3),
           !g[0].lowercased().contains("card") {
            let credit = g[2].lowercased() == "credited"
            let t = alertTail(text, after: g[0])
            return make(src, mask: g[3], amount: g[1], credit: credit, source: .bank, bankCode: bank,
                        counterparty: t.merchant, merchant: t.merchant.isEmpty ? "Bank \(credit ? "credit" : "debit")" : t.merchant,
                        narration: t.raw.isEmpty ? "Bank alert" : t.raw, date: t.date ?? headerDate)
        }
        if let g = cap(#"[Yy]our\s+(?:\w+\s+){0,2}?a(?:/c|ccount)\s*(?:no\.?|number|ending)?\s*[.:]?\s*"# + msk
                       + #"\s+(?:is|has been|was)\s+(?:successfully\s+)?(debited|credited)\s+(?:with|by|for)\s*"# + cur + amt, text, 3),
           !g[0].lowercased().contains("card") {
            let credit = g[2].lowercased() == "credited"
            let t = alertTail(text, after: g[0])
            return make(src, mask: g[1], amount: g[3], credit: credit, source: .bank, bankCode: bank,
                        counterparty: t.merchant, merchant: t.merchant.isEmpty ? "Bank \(credit ? "credit" : "debit")" : t.merchant,
                        narration: t.raw.isEmpty ? "Bank alert" : t.raw, date: t.date ?? headerDate)
        }
        return nil
    }

    // MARK: - Balance readings
    /// An exact account balance from a bank alert — captures the "as of <date>" so the newest
    /// reading wins and the live balance can be reconstructed from it. Only *account* balances
    /// qualify: a debit-card mail's "available balance on your card" is a card limit, not a
    /// deposit, and anchoring on it would corrupt the account.
    /// `txn` is the transaction already parsed from the same mail, when there was one. Alerts state
    /// the account's balance *after* the movement but name the account only in the transaction
    /// sentence, so the reading needs the transaction's mask to be attributable.
    static func balance(_ src: Source, txn: SyncedTxn? = nil) -> BalanceUpdate? {
        guard bankCode(fromSender: src.sender) != nil else { return nil }
        let text = htmlToText(src.body)
        // Daily standalone balance mail: "The available balance in your account ending XX4068 is
        // Rs. INR 1,23,456.78 as of 28-JUL-26." ("was" in the dormant-account variant.)
        if let g = cap(#"available balance in your account ending\s+"# + msk + #"\s*(?:is|was)\s*"# + cur + amt
                       + #"(?:\s*as of\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4}))?"#, text, 3), let v = money(g[2]) {
            return BalanceUpdate(mask: String(g[1].suffix(4)), balance: v, kind: .bank,
                                 asOf: endOfDay(g[3]) ?? rfcDate(src.dateHeader))
        }
        // Legacy: "Available balance in your A/c XX4068 at <BRANCH> as of 18-MAR-23 is INR 12345.69."
        if let g = cap(#"[Aa]vailable balance in your A/c\s+"# + msk + #"\s*(?:at\s+.+?)?\s*as of\s+(\d{1,2}-[A-Za-z]{3,9}-\d{2,4})\s*(?:is|was)\s*"#
                       + cur + amt, text, 3), let v = money(g[3]) {
            return BalanceUpdate(mask: String(g[1].suffix(4)), balance: v, kind: .bank,
                                 asOf: endOfDay(g[2]) ?? rfcDate(src.dateHeader))
        }
        // Post-transaction balance, stated by the SI / IMPS / deposit / salary alerts. A fresher
        // anchor than the daily mail (which is as of the previous end-of-day), so it is worth
        // taking — but only for a bank transaction whose account we know. Debit-card alerts quote
        // "available balance on your card", which is a card limit, not a deposit; they carry no
        // mask, so they are excluded twice over.
        guard let t = txn, t.source == .bank, !t.accountMask.isEmpty,
              !text.lowercased().contains("balance on your card") else { return nil }
        for p in [#"available balance(?: in your account)? is\s*"# + cur + amt,
                  #"Available Balance:\s*"# + cur + amt] {
            if let g = cap(p, text, 1), let v = money(g[1]) {
                // As-of is the send time: the figure is true at the moment the alert is raised.
                return BalanceUpdate(mask: t.accountMask, balance: v, kind: .bank, asOf: rfcDate(src.dateHeader))
            }
        }
        return nil
    }

    /// Parse a "29-JUN-26" / "29-June-2026" balance date and pin it to end-of-day, so same-day
    /// transactions (stamped at midnight) count as already included in the reading.
    private static func endOfDay(_ s: String) -> Date? {
        guard let d = date(s) else { return nil }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
    }

    // MARK: - Construction
    private static func make(_ src: Source, mask: String, amount: String, credit: Bool,
                             source: TxnSource, bankCode: String, counterparty: String,
                             merchant: String, narration: String, date: Date) -> SyncedTxn? {
        guard let v = money(amount), v > 0 else { return nil }
        return SyncedTxn(externalId: "gmail:\(src.id)", narration: narration,
                         amount: credit ? v : -v, date: date,
                         accountMask: String(mask.suffix(4)), merchant: merchant.isEmpty ? nil : merchant,
                         source: source, counterparty: counterparty.isEmpty ? nil : counterparty, bankCode: bankCode)
    }

    // MARK: - Narration → counterparty
    /// Names the payee behind an HDFC standing-instruction token. The `…added to <TOKEN> account…`
    /// slot is the only place the alert says *what* the auto-debit was for.
    static func siMerchant(_ token: String) -> String {
        let u = token.uppercased()
        // "EMI 151315644 Chq S1599999990271 0726159999999" — keep the loan account number so two
        // loans are distinguishable, and so a Loan's `counterpartyKey` can match exactly one.
        if u.hasPrefix("EMI ") || u.contains(" EMI ") {
            let num = u.components(separatedBy: " ").first { $0.count >= 6 && $0.allSatisfy { $0.isNumber } }
            return num.map { "Loan EMI \($0)" } ?? "Loan EMI"
        }
        if u.hasPrefix("CC ") || u.contains("SI-TAD") || u.contains("AUTOPAY") { return "HDFC credit card autopay" }
        if u.contains("RD INSTALLMENT") || u.contains("RD INSTALMENT") { return "RD installment" }
        // "SI HGALP0… ICICI C-29/07/26" / "… Fed Cre-04/07/26" / "… Axis Ba-04/07/26" — the biller
        // short-name sits between the mandate id and the trailing date.
        if u.hasPrefix("SI ") {
            let body = token.dropFirst(3).split(separator: "-").first.map(String.init) ?? token
            let words = body.split(separator: " ").map(String.init).filter { $0.range(of: #"^[A-Z]{4,}\d"#, options: .regularExpression) == nil }
            let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Standing instruction" : "\(name.capitalized) credit card autopay"
        }
        // "IB FUNDS TRANSFER DR-XXXXXXXXXX2421-SUHAIL P SALIM" — keep the far account's last-4 as a
        // `••NNNN` suffix so `Store.correlateOwnAccountTransfers` can recognise a move between the
        // user's own accounts and keep it out of spend/income.
        if u.contains("FUNDS TRANSFER") {
            let segs = token.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            let far = segs.first { $0.range(of: #"^[Xx*]{4,}\d{3,}$"#, options: .regularExpression) != nil }
                .map { "••\($0.suffix(4))" }
            let name = segs.last.flatMap { $0.rangeOfCharacter(from: .letters) != nil && $0.count > 3 ? $0.capitalized : nil }
            return [name ?? "Funds transfer", far].compactMap { $0 }.joined(separator: " ")
        }
        return railMerchant(token).isEmpty ? "Standing instruction" : railMerchant(token)
    }

    /// Payee display name that follows a VPA when the alert puts it outside the captured group.
    private static func vpaName(after vpa: String, in text: String) -> String {
        cap(NSRegularExpression.escapedPattern(for: vpa) + #"\s*\(([^)]+)\)"#, text, 1)?[1] ?? ""
    }

    /// Payment-rail tokens that never name a counterparty.
    /// Payment-rail tokens, and the month names that appear in period narrations
    /// ("ABCL 0678 Aug 2021 Sal") — without the months, one recurring salary produces twelve
    /// different merchants a year and never groups.
    private static let railWords: Set<String> = ["NEFT", "RTGS", "IMPS", "UPI", "ACH", "NACH", "ECS",
                                                 "SI", "TPT", "INB", "MMT", "FT", "CR", "DR", "C", "D",
                                                 "CREDIT", "DEBIT", "TRANSFER", "TRF", "REF", "UTR",
                                                 "NO", "AC", "MANDATE", "EMANDATE", "PMT", "MMID", "SAL",
                                                 "SALARY", "CHQ", "INSTALLMENT", "INSTALMENT", "QTR",
                                                 "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG",
                                                 "SEP", "SEPT", "OCT", "NOV", "DEC",
                                                 "JANUARY", "FEBRUARY", "MARCH", "APRIL", "JUNE", "JULY",
                                                 "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]

    /// Best human name from a rail narration such as
    /// `NEFT Cr-IDFB0040101-EMPLOYER NAME INC-Beneficiary-IDFB0000M1234` or
    /// `XXXXXXXXXX2024-TPT-EMPLOYER INDIA PVT LTD FEB 25 SALARY-EMPLOYER INDIA PRIVATE LIMITED`.
    /// Splits on separators, drops IFSC / reference / rail segments, returns the longest name-like
    /// run. Empty when nothing name-like survives.
    static func railMerchant(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for w in ["towards", "for", "from", "by", "via", "with", "into", "being", "thru", "through", "info", "ref", "reference", "the"] {
                if t.lowercased().hasPrefix(w + " ") || t.lowercased().hasPrefix(w + ":") {
                    t = String(t.dropFirst(w.count + 1)).trimmingCharacters(in: .whitespaces); stripped = true
                }
            }
        }
        if let vpa = t.split(whereSeparator: { " -/".contains($0) }).first(where: { $0.contains("@") }) { return String(vpa) }
        let segs = t.split(whereSeparator: { "-/,:()".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }

        /// A segment reduced to its name-like words, or "" if nothing survives.
        func nameOf(_ seg: String) -> String {
            let u = seg.uppercased()
            if u.range(of: #"^[A-Z]{4}0[A-Z0-9]{5,}$"#, options: .regularExpression) != nil { return "" }  // IFSC
            if u.range(of: #"^[Xx*]{4,}\d{3,}$"#, options: .regularExpression) != nil { return "" }        // masked a/c
            if u.range(of: #"\d{6,}"#, options: .regularExpression) != nil { return "" }                   // ref number
            return u.split(separator: " ").map(String.init)
                .filter { !railWords.contains($0) && $0.rangeOfCharacter(from: .letters) != nil }
                .joined(separator: " ")
        }

        // `NEFT Cr-<remitter IFSC>-<REMITTER>-<beneficiary>-<ref>`: the payer is the segment right
        // after the IFSC. Positional, because longest-wins picks the *beneficiary* — the account
        // holder's own name — whenever it is longer than the employer's, which silently turns every
        // salary credit into a transaction from yourself.
        if let ifsc = segs.firstIndex(where: {
            $0.uppercased().range(of: #"^[A-Z]{4}0[A-Z0-9]{5,}$"#, options: .regularExpression) != nil
        }) {
            for seg in segs[(ifsc + 1)...] {
                let n = nameOf(seg)
                if n.count > 3 { return n.capitalized }
            }
        }
        // No IFSC anchor (e.g. the intra-bank `…-TPT-<REMITTER …>-<REMITTER LTD>` shape): longest wins.
        var best = ""
        for seg in segs where nameOf(seg).count > best.count { best = nameOf(seg) }
        return best.count > 3 ? best.capitalized : ""
    }

    /// Counterparty + date pulled from the free text after a generic bank-alert match.
    private static func alertTail(_ text: String, after matched: String) -> (merchant: String, date: Date?, raw: String) {
        guard let r = text.range(of: matched) else { return ("", nil, "") }
        let tail = String(text[r.upperBound...].prefix(220))
        var before = tail, after = ""
        var when: Date? = nil
        if let g = cap(#"\bon\s+(\d{1,2}[-/ ](?:\d{1,2}|[A-Za-z]{3,9})[-/ ]\d{2,4})"#, tail, 1) {
            when = date(g[1])
            if let dr = tail.range(of: g[0]) {
                before = String(tail[..<dr.lowerBound])
                after = String(tail[dr.upperBound...])
            }
        }
        func bounded(_ s: String) -> String {
            var region = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
            if let stop = region.range(of: ". ") { region = String(region[..<stop.lowerBound]) }
            return region
        }
        var m = railMerchant(bounded(before))
        if m.isEmpty { m = railMerchant(bounded(after)) }
        return (m, when, tail.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - helpers
    static func htmlToText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, r) in ["&amp;": "&", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "'", "&apos;": "'"] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        // Decode numeric character references (&#8202; thin/hair spaces, &#160; nbsp, &#x20B9; ₹, …);
        // bank HTML alerts use these as table spacers between a label and its value.
        t = decodeNumericEntities(t)
        // Normalise every kind of space (NBSP, thin/hair/zero-width spaces, the U+FFFD replacement char
        // a bad byte decodes to) to a plain space, so "INR<nbsp>924" / "Amount<hairspace>₹265" still match.
        t = String(t.unicodeScalars.map { sc -> Character in
            if sc == "\u{FFFD}" || sc.properties.isWhitespace || sc.properties.generalCategory == .format { return " " }
            return Character(sc)
        })
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Decodes `&#NNN;` and `&#xHH;` character references (bounded so stray "&#" text is left alone).
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&", i + 1 < scalars.count, scalars[i + 1] == "#" {
                var j = i + 2
                var hex = false
                if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" { hex = true; j += 1 }
                var digits = ""
                while j < scalars.count, digits.count < 6, scalars[j] != ";" {
                    digits.unicodeScalars.append(scalars[j]); j += 1
                }
                if j < scalars.count, scalars[j] == ";", !digits.isEmpty,
                   let v = UInt32(digits, radix: hex ? 16 : 10), let sc = Unicode.Scalar(v) {
                    out.append(sc); i = j + 1; continue
                }
            }
            out.append(scalars[i]); i += 1
        }
        return String(out)
    }
    private static func money(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    private static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
        return t.range(of: #"^[A-Z0-9 .&'*-]+$"#, options: .regularExpression) != nil ? t.capitalized : t
    }
    /// Trim a merchant string at footer boilerplate and cap its length. The label-row layouts run
    /// the merchant straight into the footer once HTML whitespace is collapsed, so the stop list
    /// has to include the footer's opening words.
    private static func boundMerchant(_ s: String) -> String {
        let stop: Set<String> = ["Need", "Powered", "View", "Track", "Help", "If", "Your", "Thank",
                                 "Visit", "Not", "What", "Convert", "Check", "Head"]
        var words: [String] = []
        for w in s.split(separator: " ").map(String.init) {
            if stop.contains(w) { break }
            words.append(w); if words.count >= 5 { break }
        }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
    }
    private static func cap(_ pattern: String, _ s: String, _ groups: Int) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0...groups).map { i in i < m.numberOfRanges && m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : "" }
    }
    private static let fmts = ["dd-MM-yy", "dd-MM-yyyy", "dd MMM yyyy", "dd MMM, yyyy", "dd/MM/yyyy", "dd/MM/yy",
                               "dd-MMM-yy", "dd-MMM-yyyy", "d-MMM-yy", "d-MMM-yyyy", "d MMM yyyy",
                               "MMM d, yyyy", "MMMM d, yyyy", "d MMMM yyyy", "yyyy-MM-dd"]
    private static func date(_ s: String) -> Date? {
        var t = s.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return nil }
        // "01-JAN-26"/"DECEMBER 01, 2022" → title case: month-name parsing is case-sensitive.
        if let r = t.range(of: #"[A-Za-z]{3,9}"#, options: .regularExpression) {
            t = t.replacingCharacters(in: r, with: t[r].prefix(1).uppercased() + t[r].dropFirst().lowercased())
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts { f.dateFormat = fmt; if let d = f.date(from: t) { return d } }
        return nil
    }
    private static func rfcDate(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return df.date(from: s) ?? Date()
    }
}
