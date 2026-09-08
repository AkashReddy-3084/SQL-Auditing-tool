using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using SQLAuditor.Lib;

namespace SQLAuditor.Wpf
{
    /// <summary>
    /// "Add Configure Checklist" page. Collects one or more custom checklist items (title +
    /// description). The Area/Sub-area is never entered here: the AI layer derives it during
    /// processing on the Custom Checklist Progress page.
    /// </summary>
    public partial class ConfigureChecklistWindow : Window
    {
        public sealed class Entry : INotifyPropertyChanged
        {
            private string _title = "";
            private string _description = "";
            private int _ordinal;
            private bool _isRemovable;
            private bool _isCurrent;

            public int Ordinal
            {
                get => _ordinal;
                set { _ordinal = value; Raise(); }
            }

            /// <summary>True for the entry still being typed; it lives in the "New item" section.</summary>
            public bool IsCurrent
            {
                get => _isCurrent;
                set { _isCurrent = value; Raise(); }
            }

            /// <summary>Only entries that have moved into the "Added items" section can be removed.</summary>
            public bool IsRemovable
            {
                get => _isRemovable;
                set { _isRemovable = value; Raise(); }
            }

            public string Title
            {
                get => _title;
                set { _title = value; Raise(); Raise(nameof(DisplayTitle)); }
            }

            public string DisplayTitle =>
                string.IsNullOrWhiteSpace(_title) ? "(no title yet)" : _title.Trim();

            public string Description
            {
                get => _description;
                set { _description = value; Raise(); }
            }

            public event PropertyChangedEventHandler? PropertyChanged;

            private void Raise([CallerMemberName] string? name = null) =>
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }

        private readonly ObservableCollection<Entry> _entries = new();

        /// <summary>The requests to process, populated when the user clicks Add Custom Checklist.</summary>
        public List<CustomChecklistRequest> Requests { get; } = new();

        public ConfigureChecklistWindow()
        {
            InitializeComponent();
            AddedEntriesList.ItemsSource = _entries;
            EntriesList.ItemsSource = _entries;
            AddEntry();
        }

        private void AddEntry()
        {
            _entries.Add(new Entry { Ordinal = _entries.Count + 1 });
            Renumber();
        }

        private void Renumber()
        {
            for (var i = 0; i < _entries.Count; i++)
            {
                _entries[i].Ordinal = i + 1;
                _entries[i].IsCurrent = i == _entries.Count - 1;
                _entries[i].IsRemovable = !_entries[i].IsCurrent;
            }
        }

        private void NewEntryBtn_Click(object sender, RoutedEventArgs e)
        {
            var current = _entries.LastOrDefault();
            if (current != null &&
                (string.IsNullOrWhiteSpace(current.Title) || string.IsNullOrWhiteSpace(current.Description)))
            {
                StatusText.Text = $"Complete the title and description for custom checklist item {current.Ordinal} before adding another one.";
                return;
            }

            StatusText.Text = "";
            AddEntry();
            Dispatcher.BeginInvoke(new System.Action(() => PageScroll.ScrollToEnd()),
                System.Windows.Threading.DispatcherPriority.Loaded);
        }

        private void RemoveEntry_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Tag: Entry entry })
            {
                if (_entries.Count == 1)
                {
                    StatusText.Text = "At least one custom checklist entry is required.";
                    return;
                }

                _entries.Remove(entry);
                Renumber();
            }
        }

        private void AddCustomChecklistBtn_Click(object sender, RoutedEventArgs e)
        {
            var filled = _entries
                .Where(x => !string.IsNullOrWhiteSpace(x.Title) || !string.IsNullOrWhiteSpace(x.Description))
                .ToList();

            if (filled.Count == 0)
            {
                StatusText.Text = "Enter a title and a description for at least one custom checklist item.";
                return;
            }

            var incomplete = filled.FirstOrDefault(x =>
                string.IsNullOrWhiteSpace(x.Title) || string.IsNullOrWhiteSpace(x.Description));
            if (incomplete != null)
            {
                StatusText.Text = $"Custom checklist item {incomplete.Ordinal} needs both a title and a description.";
                return;
            }

            var duplicateTitle = filled
                .GroupBy(x => x.Title.Trim(), System.StringComparer.OrdinalIgnoreCase)
                .FirstOrDefault(g => g.Count() > 1);
            if (duplicateTitle != null)
            {
                StatusText.Text = $"The title '{duplicateTitle.Key}' is used more than once. Give each entry a distinct title.";
                return;
            }

            Requests.Clear();
            foreach (var entry in filled)
            {
                Requests.Add(new CustomChecklistRequest
                {
                    Title = entry.Title.Trim(),
                    Description = entry.Description.Trim()
                });
            }

            DialogResult = true;
        }

        private void CancelBtn_Click(object sender, RoutedEventArgs e) => DialogResult = false;
    }
}
