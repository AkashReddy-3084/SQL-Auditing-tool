using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using SQLAuditor.Agents;

class Program
{
    static async Task Main(string[] args)
    {

        var basePath = args.Length > 0
            ? Path.GetFullPath(args[0])
            : Directory.GetParent(
                Directory.GetCurrentDirectory())!.FullName;


        Console.WriteLine("==============================================");
        Console.WriteLine(" SQL Auditing - Script Generator Agent");
        Console.WriteLine(" Checklist → LLM → SQL/PS1 Scripts");
        Console.WriteLine("==============================================");
        Console.WriteLine();


        //
        // Load configuration
        //
        var configPath =
            Path.Combine(
                basePath,
                "agents",
                "config",
                "appsettings.json");

        if (!File.Exists(configPath))
        {
            Console.WriteLine(
                $"Config file not found: {configPath}");
            return;
        }

        using var config =
            JsonDocument.Parse(
                File.ReadAllText(configPath));

        var root =
            config.RootElement;

        var llmBaseUrl =
            root
            .GetProperty("LLM")
            .GetProperty("BaseUrl")
            .GetString()!;

        var llmApiKey =
            root
            .GetProperty("LLM")
            .GetProperty("ApiKey")
            .GetString()!;

        var llmModel =
            root
            .GetProperty("LLM")
            .GetProperty("Model")
            .GetString()!;

        var llmTimeout =
            root.GetProperty("LLM")
            .TryGetProperty("TimeoutSeconds", out var t)
            ? t.GetInt32()
            : 300;

        var llmRetries =
            root.GetProperty("LLM")
            .TryGetProperty("MaxRetries", out var r)
            ? r.GetInt32()
            : 3;

        var promptsDirectory =
            Path.Combine(
                basePath,
                "agents",
                "prompts");


        //
        // Initialize components
        //

        var processor =
            new ChecklistItemProcessor(
                llmBaseUrl,
                llmApiKey,
                llmModel,
                promptsDirectory,
                llmTimeout,
                llmRetries);

        var validator =
            new ScriptOutputValidator();

        var agent =
            new ScriptGeneratorAgent(
                processor,
                validator,
                basePath);


        try
        {
            var result =
                await agent.RunAsync();

            Console.WriteLine();
            Console.WriteLine(
                "============== SUMMARY ==============");

            Console.WriteLine(
                $"Generated : {result.Generated.Count}");

            Console.WriteLine(
                $"Skipped   : {result.Skipped.Count}");

            Console.WriteLine(
                $"Failed    : {result.Failed.Count}");

            if (result.Skipped.Count > 0)
            {
                Console.WriteLine();
                Console.WriteLine(
                    "Skipped Items:");

                foreach (var item in result.Skipped)
                {
                    Console.WriteLine(
                        $"  {item.ChecklistId} - {item.CheckName}");
                    Console.WriteLine(
                        $"  Reason: {item.Reason}");
                }
            }

            Console.WriteLine();
            Console.WriteLine(
                "Results:");
            Console.WriteLine(
                Path.Combine(
                    basePath,
                    "results",
                    "execution-results.json"));
        }
        catch (Exception ex)
        {
            Console.WriteLine();
            Console.WriteLine(
                "Agent failed:");
            Console.WriteLine(
                ex.Message);
        }
    }
}