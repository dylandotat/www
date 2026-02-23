using Microsoft.AspNetCore.Mvc.RazorPages;

namespace dylan.at.Pages.Admin;

public class Index : PageModel
{
    public string Username { get; private set; } = "admin";

    public void OnGet()
    {
        Username = User.Identity?.Name ?? "admin";
    }
}
