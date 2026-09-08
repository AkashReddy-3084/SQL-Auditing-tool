using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace SQLAuditor.Agents
{
    /// <summary>
    /// Deterministic gate run on every generated script before it is written to disk.
    /// Rejects truncated output, placeholder stubs, a broken output contract and any
    /// statement that could write to the server. Each message is fed back to the LLM as
    /// retry context, so it states what has to change.
    /// </summary>
    public class ScriptOutputValidator
    {
        private const RegexOptions Opts =
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

        private static readonly string[] OutputColumns =
            { "Result", "Score", "DatabaseQueried", "Finding" };

        private const string FinalSelect =
            "SELECT @Result AS Result, @Score AS Score, " +
            "@DatabaseQueried AS DatabaseQueried, @Finding AS Finding;";

        private static readonly (Regex Rule, string Message)[] PlaceholderRules =
        {
            (new Regex(@"<[a-z_]{3,}>", Opts), "an unfilled <placeholder> token"),
            (new Regex(@"\bTODO\b", Opts), "a TODO marker"),
            (new Regex(@"(--|#)[^\r\n]*\.\.\.", Opts), "a '...' placeholder comment instead of real logic"),
        };

        // Applied to executable code, and statement-anchored to dynamic SQL text.
        private static readonly (string Pattern, string Message)[] SqlWritePatterns =
        {
            (@"INSERT\s+INTO\s+(?![#@])[\w\[]|INSERT\s+(?!INTO\b)(?![#@])[\w\[]", "INSERT against a non-temporary object"),
            (@"UPDATE\s+(?![#@])[\w\[][\w\[\]\.]*\s+SET\b", "UPDATE against a non-temporary object"),
            (@"UPDATE\s+STATISTICS\b", "UPDATE STATISTICS"),
            (@"DELETE\s+FROM\s+(?![#@])[\w\[]|DELETE\s+(?!FROM\b)(?![#@])[\w\[]", "DELETE against a non-temporary object"),
            (@"MERGE\s+(?![#@])[\w\[]", "MERGE"),
            (@"TRUNCATE\s+TABLE\b", "TRUNCATE TABLE"),
            (@"CREATE\s+(?!TABLE\s+#)\w", "CREATE of a permanent object"),
            (@"ALTER\s+\w", "ALTER"),
            (@"DROP\s+(?!TABLE\s+#)\w", "DROP of a permanent object"),
            (@"(?<!\bINSERT\s{1,20})INTO\s+(?![#@])[\w\[]", "SELECT ... INTO a permanent table"),
            (@"(GRANT|REVOKE|DENY)\s+\w", "a permission change"),
            (@"sp_configure\b[^\r\n;]*,", "sp_configure with a value"),
            (@"RECONFIGURE\b", "RECONFIGURE"),
            (@"(BACKUP|RESTORE)\s+(DATABASE|LOG|CERTIFICATE|MASTER\s+KEY)\b", "BACKUP/RESTORE"),
            (@"xp_cmdshell\b", "xp_cmdshell"),
            (@"DBCC\s+(FREEPROCCACHE|FREESYSTEMCACHE|DROPCLEANBUFFERS|SHRINK\w*|CHECKIDENT|WRITEPAGE)\b", "a state-changing DBCC command"),
            (@"(BEGIN|COMMIT|ROLLBACK)\s+(TRAN|TRANSACTION)\b", "an explicit transaction"),
            (@"SHUTDOWN\b", "SHUTDOWN"),
        };

        private static readonly (Regex Rule, string Message)[] CodeWriteRules =
            Array.ConvertAll(
                SqlWritePatterns,
                r => (new Regex(@"\b(?:" + r.Pattern + ")", Opts), r.Message));

        private static readonly (Regex Rule, string Message)[] DynamicSqlWriteRules =
            Array.ConvertAll(
                SqlWritePatterns,
                r => (new Regex(@"^[\s;]*(?:" + r.Pattern + ")", Opts | RegexOptions.Multiline), r.Message));

        private static readonly Regex PowerShellWriteRule = new(
            @"\b(Set-(Item|ItemProperty|Content|Service|Acl|Location)|" +
            @"New-(Item|ItemProperty|Service)|Remove-\w+|Add-Content|Clear-\w+|" +
            @"Rename-Item|Move-Item|Copy-Item|(Start|Stop|Restart|Suspend|Resume)-Service|" +
            @"Stop-Process|Out-File|Invoke-Expression)\b", Opts);


        public ValidationResult Validate(
            ScriptGenerationResponse response)
        {

            if (!response.IsFeasible)
            {
                return new ValidationResult
                {
                    IsValid = true
                };
            }


            if (response.IsTruncated)
            {
                return Invalid(
                    "Script is incomplete - the answer was cut off before ---SCRIPT_END---. " +
                    "Regenerate a shorter, self-contained script that ends with the final SELECT.");
            }


            // Script content is required
            if (string.IsNullOrWhiteSpace(response.ScriptContent))
            {
                return Invalid(
                    "Script content empty");
            }


            // ScriptType should exist after fallback inference
            if (string.IsNullOrWhiteSpace(response.ScriptType))
            {
                return Invalid(
                    "Missing SCRIPT_TYPE and could not infer from content");
            }

            if (!string.Equals(response.Scope, "SERVER", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(response.Scope, "DATABASE", StringComparison.OrdinalIgnoreCase))
            {
                return Invalid(
                    "Missing or invalid SCOPE; emit exactly SCOPE: SERVER or SCOPE: DATABASE");
            }


            // ScriptName should exist after fallback generation
            if (string.IsNullOrWhiteSpace(response.ScriptName))
            {
                return Invalid(
                    "Missing SCRIPT_NAME");
            }


            // Validate script content based on type
            if (response.ScriptType.Equals(
                "sql",
                StringComparison.OrdinalIgnoreCase))
            {
                return ValidateSql(
                    response.ScriptContent,
                    response.Scope);
            }


            if (response.ScriptType.Equals(
                "ps1",
                StringComparison.OrdinalIgnoreCase))
            {
                return ValidatePowerShell(
                    response.ScriptContent);
            }


            return Invalid(
                $"Unsupported script type {response.ScriptType}");
        }


        private ValidationResult ValidateSql(
            string script,
            string? scope = null)
        {
            var tokens = Tokenize(script);
            var code = tokens.Code;

            var placeholder = FindPlaceholder(
                code + "\n" + string.Join("\n", tokens.Comments));

            if (placeholder != null)
            {
                return Invalid(
                    $"SQL script contains {placeholder}. Emit the complete evaluation logic.");
            }


            // ---- completeness -------------------------------------------------

            if (tokens.UnterminatedLiteral)
            {
                return Invalid(
                    "SQL script has an unterminated string literal - it is cut off " +
                    "or a quote inside dynamic SQL is not doubled.");
            }

            var parens =
                CountChar(code, '(') - CountChar(code, ')');

            if (parens != 0)
            {
                return Invalid(
                    $"SQL script has unbalanced parentheses ({Math.Abs(parens)} " +
                    $"{(parens > 0 ? "unclosed" : "unmatched closing")}) - it is incomplete or malformed.");
            }

            if (CountMatches(code, @"\bBEGIN\s+TRY\b") != CountMatches(code, @"\bEND\s+TRY\b") ||
                CountMatches(code, @"\bBEGIN\s+CATCH\b") != CountMatches(code, @"\bEND\s+CATCH\b"))
            {
                return Invalid(
                    "SQL script has an unbalanced BEGIN TRY / END TRY / BEGIN CATCH / END CATCH block.");
            }

            if (Regex.IsMatch(code, @"\bDECLARE\s+[\w@#]+\s+(INSENSITIVE\s+|SCROLL\s+)*CURSOR\b", Opts) &&
                !(Regex.IsMatch(code, @"\bCLOSE\s+[\w@#]+", Opts) &&
                  Regex.IsMatch(code, @"\bDEALLOCATE\s+[\w@#]+", Opts)))
            {
                return Invalid(
                    "SQL script declares a cursor but never CLOSEs and DEALLOCATEs it.");
            }


            // ---- output contract ----------------------------------------------

            if (!Regex.IsMatch(code, @"@Result", Opts))
            {
                return Invalid(
                    "SQL script missing @Result variable");
            }

            if (!Regex.IsMatch(code, @"@Score", Opts))
            {
                return Invalid(
                    "SQL script missing @Score variable");
            }

            if (!Regex.IsMatch(code, @"@Result\s*=\s*CASE\b[\s\S]{0,160}?@Score", Opts))
            {
                return Invalid(
                    "@Result must be derived from @Score. Use exactly: " +
                    "SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;");
            }

            // Matched on the raw script because Tokenize strips literals out of Code.
            var resultCase = Regex.Match(script, @"@Result\s*=\s*CASE\b[\s\S]{0,400}?\bEND\b", Opts);

            if (resultCase.Success)
            {
                foreach (Match verdict in Regex.Matches(resultCase.Value, @"\b(?:THEN|ELSE)\s*N?'([^']*)'", Opts))
                {
                    var value = verdict.Groups[1].Value.Trim();

                    if (!value.Equals("Pass", StringComparison.OrdinalIgnoreCase) &&
                        !value.Equals("Fail", StringComparison.OrdinalIgnoreCase))
                    {
                        return Invalid(
                            $"@Result may only be 'Pass' or 'Fail' but the script can return '{value}', " +
                            "which leaves the checklist item without a verdict. Use exactly: " +
                            "SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;");
                    }
                }
            }

            var lastSelect =
                code.LastIndexOf("SELECT", StringComparison.OrdinalIgnoreCase);

            if (lastSelect < 0)
            {
                return Invalid(
                    "SQL script has no SELECT statement - it is empty, truncated or only comments.");
            }

            var tail = code.Substring(lastSelect);

            foreach (var column in OutputColumns)
            {
                if (!Regex.IsMatch(tail, $@"\bAS\s+\[?{column}\]?\b", Opts))
                {
                    return Invalid(
                        $"The last statement must be the four-column output SELECT and " +
                        $"'{column}' is missing from it. End the script with: {FinalSelect}");
                }
            }


            // ---- read-only ------------------------------------------------------

            var write = FindWrite(code, CodeWriteRules);

            if (write != null)
            {
                return Invalid(
                    $"Script must be strictly read-only but contains {write}. " +
                    "Only SELECT against system views is allowed; #temp tables and " +
                    "@table variables are the sole writable targets.");
            }

            foreach (var literal in tokens.Literals)
            {
                if (!Regex.IsMatch(literal, @"\b(SELECT|FROM|EXEC)\b", Opts))
                    continue;

                write = FindWrite(literal, DynamicSqlWriteRules);

                if (write != null)
                {
                    return Invalid(
                        $"Dynamic SQL must be read-only but contains {write}.");
                }
            }


            // ---- database execution scope ---------------------------------------

            if (string.Equals(scope, "DATABASE", StringComparison.OrdinalIgnoreCase))
            {
                if (!Regex.IsMatch(code, @"@DatabaseQueried\b[^;]{0,300}\bDB_NAME\s*\(", Opts))
                {
                    return Invalid(
                        "A DATABASE-scope script must set @DatabaseQueried from DB_NAME(); " +
                        "the backend selects and connects to each target database at runtime.");
                }

                if (Regex.IsMatch(
                    code,
                    @"\b(FROM|JOIN)\s+(?:(?:\[?master\]?)\s*\.\s*)?(?:\[?sys\]?)\s*\.\s*(?:\[?databases\]?)\b",
                    Opts))
                {
                    return Invalid(
                        "A DATABASE-scope script must not discover targets through sys.databases; " +
                        "query only the current database selected by the backend.");
                }

                var combinedLiterals = string.Join(" ", tokens.Literals);
                if (Regex.IsMatch(
                    combinedLiterals,
                    @"\b(FROM|JOIN)\s+(?:(?:\[?master\]?)\s*\.\s*)?(?:\[?sys\]?)\s*\.\s*(?:\[?databases\]?)\b",
                    Opts))
                {
                    return Invalid(
                        "A DATABASE-scope script must not build dynamic SQL that discovers " +
                        "targets through sys.databases; query only the current database.");
                }
            }


            return Valid();
        }


        private ValidationResult ValidatePowerShell(
            string script)
        {
            var placeholder = FindPlaceholder(script);

            if (placeholder != null)
            {
                return Invalid(
                    $"PowerShell script contains {placeholder}. Emit the complete evaluation logic.");
            }

            foreach (var property in OutputColumns)
            {
                if (!Regex.IsMatch(script, $@"\b{property}\b", Opts))
                {
                    return Invalid(
                        $"PowerShell script must emit Result, Score, DatabaseQueried and " +
                        $"Finding - '{property}' is missing.");
                }
            }

            if (!script.Contains("PSCustomObject", StringComparison.OrdinalIgnoreCase))
            {
                return Invalid(
                    "PowerShell script must end with a [PSCustomObject] carrying " +
                    "Result, Score, DatabaseQueried and Finding.");
            }

            var write = PowerShellWriteRule.Match(script);

            if (write.Success)
            {
                return Invalid(
                    $"Script must be strictly read-only but uses '{write.Value}'. " +
                    "Use read-only cmdlets only (Get-*, Test-Path, Select-Object).");
            }

            return Valid();
        }


        private static string? FindPlaceholder(
            string text)
        {
            foreach (var (rule, message) in PlaceholderRules)
            {
                if (rule.IsMatch(text))
                    return message;
            }

            return null;
        }


        private static string? FindWrite(
            string text,
            (Regex Rule, string Message)[] rules)
        {
            foreach (var (rule, message) in rules)
            {
                if (rule.IsMatch(text))
                    return message;
            }

            return null;
        }


        private static int CountChar(
            string text,
            char value)
        {
            var count = 0;

            foreach (var c in text)
            {
                if (c == value)
                    count++;
            }

            return count;
        }


        private static int CountMatches(
            string text,
            string pattern)
        {
            return Regex.Matches(text, pattern, Opts).Count;
        }


        /// <summary>
        /// Splits a T-SQL script into executable code, comments and string literals so each
        /// can be checked with the right strictness (dynamic SQL lives inside literals).
        /// </summary>
        private static SqlTokens Tokenize(
            string script)
        {
            var tokens = new SqlTokens();
            var code = new StringBuilder(script.Length);
            var i = 0;

            while (i < script.Length)
            {
                var c = script[i];

                if (c == '-' && i + 1 < script.Length && script[i + 1] == '-')
                {
                    var start = i;
                    while (i < script.Length && script[i] != '\n') i++;
                    tokens.Comments.Add(script.Substring(start, i - start));
                    continue;
                }

                if (c == '/' && i + 1 < script.Length && script[i + 1] == '*')
                {
                    var start = i;
                    i += 2;
                    while (i + 1 < script.Length && !(script[i] == '*' && script[i + 1] == '/')) i++;
                    i = Math.Min(i + 2, script.Length);
                    tokens.Comments.Add(script.Substring(start, i - start));
                    continue;
                }

                if (c == '\'')
                {
                    i++;
                    var literal = new StringBuilder();
                    var terminated = false;

                    while (i < script.Length)
                    {
                        if (script[i] == '\'')
                        {
                            if (i + 1 < script.Length && script[i + 1] == '\'')
                            {
                                literal.Append('\'');
                                i += 2;
                                continue;
                            }

                            terminated = true;
                            i++;
                            break;
                        }

                        literal.Append(script[i]);
                        i++;
                    }

                    tokens.Literals.Add(literal.ToString());
                    tokens.UnterminatedLiteral |= !terminated;
                    code.Append(" '' ");
                    continue;
                }

                code.Append(c);
                i++;
            }

            tokens.Code = code.ToString();
            return tokens;
        }


        private sealed class SqlTokens
        {
            public string Code { get; set; } = "";

            public List<string> Comments { get; } = new();

            public List<string> Literals { get; } = new();

            public bool UnterminatedLiteral { get; set; }
        }


        private ValidationResult Valid()
        {
            return new ValidationResult
            {
                IsValid = true
            };
        }


        private ValidationResult Invalid(
            string message)
        {
            return new ValidationResult
            {
                IsValid = false,
                Error = message
            };
        }
    }


    public class ValidationResult
    {
        public bool IsValid { get; set; }

        public string Error { get; set; } = "";
    }
}