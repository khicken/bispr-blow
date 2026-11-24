using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace BisprBlow;

public enum AccountMode { Account, SignIn, Team }

// The account UI in its three homes: the Settings group (Account), the bare sign-in form (SignIn), and the
// create/join form or the team you are in (Team). The views only read CloudClient.Shared and call it;
// nothing here is the source of truth.
public partial class AccountView : UserControl
{
    AccountMode mode = AccountMode.Account;
    bool showsBlurb = true;

    public AccountMode Mode { get => mode; set { mode = value; Refresh(); } }
    public bool ShowsBlurb { get => showsBlurb; set { showsBlurb = value; Refresh(); } }

    // Sign-in state
    bool codeSent, busy, googleWaiting, confirmingSignOut;
    int runId;
    string? note;

    // Team state
    bool creating, confirmingLeave, renaming, copied;
    string? teamNote, inviteCode, invitedEmail;
    Guid? refreshedFor;

    static CloudClient Cloud => CloudClient.Shared;

    public AccountView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Cloud.PropertyChanged += OnCloudChanged;
            AppSettings.Shared.PropertyChanged += OnSettingsChanged;
            Refresh();
            RefreshTeam();
        };
        Unloaded += (_, _) =>
        {
            Cloud.PropertyChanged -= OnCloudChanged;
            AppSettings.Shared.PropertyChanged -= OnSettingsChanged;
        };
        EmailField.KeyDown += (_, e) => Enter(e, () => Submit_Click(null!, null!));
        CodeField.KeyDown += (_, e) => Enter(e, () => Submit_Click(null!, null!));
        JoinCodeField.KeyDown += (_, e) => Enter(e, () => Join_Click(null!, null!));
        TeamNameField.KeyDown += (_, e) => Enter(e, () => Join_Click(null!, null!));
        TeamNameField.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            creating = false;
            e.Handled = true;
            Refresh();
        };
        InviteField.KeyDown += (_, e) => Enter(e, () => Invite_Click(null!, null!));
        RenameField.KeyDown += (_, e) => Enter(e, CommitRename);
        RenameField.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            renaming = false;
            e.Handled = true;
            Refresh();
        };
    }

    static void Enter(KeyEventArgs e, Action action)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        action();
    }

    void OnCloudChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        if (e.PropertyName == nameof(CloudClient.Session))
        {
            // A new sign-in starts clean; a sign-out forgets half-typed state.
            codeSent = false;
            busy = false;
            googleWaiting = false;
            note = null;
            confirmingSignOut = false;
            CodeField.Text = "";
            if (Cloud.Session != null) EmailField.Text = "";
        }
        if (e.PropertyName == nameof(CloudClient.Org))
        {
            creating = false;
            confirmingLeave = false;
            renaming = false;
            inviteCode = null;
            teamNote = null;
        }
        Refresh();
        if (e.PropertyName is nameof(CloudClient.Session)) RefreshTeam();
    });

    void OnSettingsChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Refresh);

    // A team view fetches once per signed-in user, so reopening the page is not a round trip each time.
    async void RefreshTeam()
    {
        if (mode != AccountMode.Team || Cloud.Session is not { } session || refreshedFor == session.UserID) return;
        refreshedFor = session.UserID;
        try { await Cloud.RefreshOrgAsync(); }
        catch (Exception e) { Log.Line($"team refresh failed: {e.Message}"); }
    }

    static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    static void Circle(Border border, string name, double size)
    {
        var initial = name.Trim().Length > 0 ? name.Trim()[..1].ToUpperInvariant() : "?";
        border.Width = border.Height = size;
        border.CornerRadius = new CornerRadius(size / 2);
        border.SetResourceReference(Border.BackgroundProperty, "Bj.BlueSoft");
        var text = new TextBlock
        {
            Text = initial,
            FontWeight = FontWeights.SemiBold,
            FontSize = size * 0.42,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Blue");
        text.SetResourceReference(TextBlock.FontFamilyProperty, "Bj.Font");
        border.Child = text;
    }

    static void SetNote(TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = Show(!string.IsNullOrEmpty(text));
    }

    void Refresh()
    {
        if (!IsInitialized) return;
        var session = Cloud.Session;
        var signedIn = session != null;
        var settings = AppSettings.Shared;

        AccountPanel.Visibility = Show(mode == AccountMode.Account && signedIn);
        SignInPanel.Visibility = Show(!signedIn);
        SignInPanel.Margin = mode == AccountMode.Account ? new Thickness(11, 10, 11, 10) : new Thickness(0);
        TeamHost.Visibility = Show(mode == AccountMode.Team && signedIn);

        if (session != null)
        {
            Circle(AccountCircle, session.Email, 28);
            EmailText.Text = session.Email;
            SignOutConfirm.Visibility = Show(confirmingSignOut);
            SignOutButton.Visibility = Show(!confirmingSignOut);
            TextsRow.Visibility = Show(settings.SyncStats);
        }

        // Sign-in
        Blurb.Visibility = Show(showsBlurb);
        SetNote(AuthNoteText, Cloud.AuthNote);
        EmailField.IsEnabled = !codeSent && !busy;
        CodeField.Visibility = Show(codeSent);
        SubmitButton.Content = (codeSent ? "Sign in" : "Email me a code") + (busy && !googleWaiting ? "…" : "");
        SubmitButton.IsEnabled = !busy;
        CodeSentRow.Visibility = Show(codeSent);
        CodeSentText.Text = $"Check {EmailField.Text.Trim()} for a code. It expires in 1 hour.";
        GoogleButton.IsEnabled = !busy || googleWaiting;
        GoogleWait.Visibility = Show(googleWaiting);
        SetNote(SignInNote, note);

        // Team
        var org = Cloud.Org;
        JoinPanel.Visibility = Show(org == null);
        TeamPanel.Visibility = Show(org != null);
        JoinHeading.Text = creating ? "Start a team" : "Join a team";
        TeamNameField.Visibility = Show(creating);
        JoinCodeField.Visibility = Show(!creating);
        JoinButton.Content = (creating ? "Create" : "Join") + (busy ? "…" : "");
        JoinButton.IsEnabled = !busy;
        CreatingToggle.Content = creating ? "Join with a code" : "Start a new team";
        SetNote(TeamNote, teamNote);
        if (org != null)
        {
            Circle(OrgCircle, org.Name, 40);
            OrgNameText.Text = org.Name;
            OrgNameButton.IsEnabled = org.IsOwner;
            OrgNameButton.Cursor = org.IsOwner ? Cursors.Hand : Cursors.Arrow;
            PencilIcon.Visibility = Show(org.IsOwner);
            OrgNameButton.Visibility = Show(!renaming);
            RenameField.Visibility = Show(renaming);
            var count = Cloud.Roster.Count;
            MemberCount.Text = count == 1 ? "1 member" : $"{count} members";
            LeaveButton.Visibility = Show(!org.IsOwner && !confirmingLeave);
            LeaveConfirm.Visibility = Show(!org.IsOwner && confirmingLeave);
            OwnerPanel.Visibility = Show(org.IsOwner);
            InviteButton.Content = "Invite" + (busy ? "…" : "");
            InviteButton.IsEnabled = !busy;
            InviteCodeRow.Visibility = Show(inviteCode != null);
            InviteCodeText.Text = inviteCode ?? "";
            InviteForText.Text = $"Send this to {invitedEmail}";
            CopyText.Text = copied ? "Copied" : "Copy";
        }
    }

    // One in-flight action at a time. A superseded run (Cancel, or a second Google click) neither
    // shows its error nor clears the newer run's busy state.
    async Task Run(Func<Task> work, Action<string?> setNote)
    {
        var id = ++runId;
        busy = true;
        setNote(null);
        Refresh();
        try { await work(); }
        catch (OperationCanceledException) { }
        catch (Exception e) when (id == runId) { setNote(e.Message); }
        catch (Exception) { }
        if (id == runId) busy = false;
        Refresh();
    }

    // MARK: Sign-in

    async void Submit_Click(object sender, RoutedEventArgs e)
    {
        var email = EmailField.Text.Trim();
        if (busy || email.Length == 0) return;
        Cloud.AuthNote = null;
        if (!codeSent)
        {
            await Run(async () =>
            {
                await Cloud.RequestCodeAsync(email);
                codeSent = true;
            }, n => note = n);
            if (codeSent) CodeField.Focus();
        }
        else
        {
            var code = CodeField.Text.Trim();
            if (code.Length == 0) return;
            await Run(() => Cloud.SignInAsync(email, code), n => note = n);
        }
    }

    void BackToEmail_Click(object sender, RoutedEventArgs e)
    {
        codeSent = false;
        note = null;
        CodeField.Text = "";
        Refresh();
        EmailField.Focus();
    }

    async void Resend_Click(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        var email = EmailField.Text.Trim();
        await Run(() => Cloud.RequestCodeAsync(email), n => note = n);
    }

    async void Google_Click(object sender, RoutedEventArgs e)
    {
        Cloud.AuthNote = null;
        Cloud.CancelGoogle();
        googleWaiting = true;
        await Run(Cloud.SignInWithGoogleAsync, n => note = n);
        googleWaiting = false;
        Refresh();
    }

    void CancelGoogle_Click(object sender, RoutedEventArgs e)
    {
        runId++;
        busy = false;
        googleWaiting = false;
        Cloud.CancelGoogle();
        Refresh();
    }

    // MARK: Account

    void SignOut_Click(object sender, RoutedEventArgs e)
    {
        // Nothing is backed up unless a toggle is on, so there is nothing to warn about.
        if (!AppSettings.Shared.SyncStats) ConfirmSignOut_Click(sender, e);
        else
        {
            confirmingSignOut = true;
            Refresh();
        }
    }

    async void ConfirmSignOut_Click(object sender, RoutedEventArgs e)
    {
        confirmingSignOut = false;
        try { await Cloud.SignOutAsync(); }
        catch (Exception ex) { Log.Line($"sign-out failed: {ex.Message}"); }
        Refresh();
    }

    void CancelSignOut_Click(object sender, RoutedEventArgs e)
    {
        confirmingSignOut = false;
        Refresh();
    }

    // MARK: Team

    void CreatingToggle_Click(object sender, RoutedEventArgs e)
    {
        creating = !creating;
        teamNote = null;
        Refresh();
    }

    async void Join_Click(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        if (creating)
        {
            var name = TeamNameField.Text.Trim();
            if (name.Length == 0) return;
            await Run(() => Cloud.CreateOrgAsync(name), n => teamNote = n);
        }
        else
        {
            var code = JoinCodeField.Text.Trim().ToUpperInvariant();
            if (code.Length == 0) return;
            await Run(() => Cloud.JoinOrgAsync(code), n => teamNote = n);
        }
        if (Cloud.Org != null)
        {
            TeamNameField.Text = "";
            JoinCodeField.Text = "";
        }
    }

    void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (Cloud.Org is not { IsOwner: true } org) return;
        renaming = true;
        RenameField.Text = org.Name;
        Refresh();
        RenameField.Focus();
        RenameField.SelectAll();
    }

    async void CommitRename()
    {
        var name = RenameField.Text.Trim();
        renaming = false;
        if (name.Length > 0 && name != Cloud.Org?.Name)
            await Run(() => Cloud.RenameOrgAsync(name), n => teamNote = n);
        else Refresh();
    }

    void Leave_Click(object sender, RoutedEventArgs e)
    {
        confirmingLeave = true;
        Refresh();
    }

    void CancelLeave_Click(object sender, RoutedEventArgs e)
    {
        confirmingLeave = false;
        Refresh();
    }

    async void ConfirmLeave_Click(object sender, RoutedEventArgs e)
    {
        confirmingLeave = false;
        await Run(Cloud.LeaveOrgAsync, n => teamNote = n);
    }

    async void Invite_Click(object sender, RoutedEventArgs e)
    {
        var email = InviteField.Text.Trim();
        if (busy || email.Length == 0) return;
        await Run(async () =>
        {
            var code = await Cloud.CreateInviteAsync(email);
            inviteCode = code;
            invitedEmail = email;
            InviteField.Text = "";
        }, n => teamNote = n);
    }

    void CopyCode_Click(object sender, RoutedEventArgs e)
    {
        if (inviteCode == null) return;
        try { Clipboard.SetText(inviteCode); }
        catch (System.Runtime.InteropServices.ExternalException) { return; }
        copied = true;
        Refresh();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            copied = false;
            Refresh();
        };
        timer.Start();
    }
}
