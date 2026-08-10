using System;
using System.Text.RegularExpressions;

namespace SQLAuditor.Agents
{
    public class ScriptOutputValidator
    {

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
                    response.ScriptContent);
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
            string script)
        {

            // Check for @Result — flexible patterns
            bool hasResult =
                Regex.IsMatch(
                    script,
                    @"@Result",
                    RegexOptions.IgnoreCase);


            // Check for @Score — flexible patterns
            bool hasScore =
                Regex.IsMatch(
                    script,
                    @"@Score",
                    RegexOptions.IgnoreCase);


            // Check for SELECT output with Result and Score
            bool hasOutput =
                Regex.IsMatch(
                    script,
                    @"SELECT\s+.*Result.*Score",
                    RegexOptions.IgnoreCase |
                    RegexOptions.Singleline)
                ||
                Regex.IsMatch(
                    script,
                    @"SELECT\s+.*Score.*Result",
                    RegexOptions.IgnoreCase |
                    RegexOptions.Singleline);


            if (!hasResult)
            {
                return Invalid(
                    "SQL script missing @Result variable");
            }

            if (!hasScore)
            {
                return Invalid(
                    "SQL script missing @Score variable");
            }

            if (!hasOutput)
            {
                return Invalid(
                    "SQL script does not SELECT Result and Score");
            }


            return new ValidationResult
            {
                IsValid = true
            };
        }


        private ValidationResult ValidatePowerShell(
            string script)
        {

            bool hasResult =
                script.Contains(
                    "Result",
                    StringComparison.OrdinalIgnoreCase);

            bool hasScore =
                script.Contains(
                    "Score",
                    StringComparison.OrdinalIgnoreCase);


            if (!hasResult)
            {
                return Invalid(
                    "PowerShell missing Result property");
            }

            if (!hasScore)
            {
                return Invalid(
                    "PowerShell missing Score property");
            }


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