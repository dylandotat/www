using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace dylan.at.Pages.Admin;

public class Login : PageModel
{
    private readonly IConfiguration _configuration;

    public Login(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    [BindProperty]
    public string Password { get; set; } = string.Empty;

    [BindProperty(SupportsGet = true)]
    public string? ReturnUrl { get; set; }

    public IActionResult OnGet()
    {
        if (User.Identity?.IsAuthenticated == true)
        {
            return LocalRedirect(GetSafeReturnUrl(ReturnUrl));
        }

        return Page();
    }

    public async Task<IActionResult> OnPostAsync()
    {
        var configuredPassword = _configuration["ADMIN_PASSWORD"];

        if (string.IsNullOrEmpty(configuredPassword))
        {
            ModelState.AddModelError(string.Empty, "Admin auth is not configured.");
            return Page();
        }

        if (!PasswordsMatch(Password, configuredPassword))
        {
            ModelState.AddModelError(string.Empty, "Invalid password.");
            return Page();
        }

        var claims = new List<Claim>
        {
            new(ClaimTypes.Name, "admin")
        };

        var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
        var principal = new ClaimsPrincipal(identity);
        var properties = new AuthenticationProperties
        {
            IsPersistent = true,
            ExpiresUtc = DateTimeOffset.UtcNow.AddDays(7)
        };

        await HttpContext.SignInAsync(
            CookieAuthenticationDefaults.AuthenticationScheme,
            principal,
            properties);

        return LocalRedirect(GetSafeReturnUrl(ReturnUrl));
    }

    public async Task<IActionResult> OnPostLogoutAsync()
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        return RedirectToPage("/Admin/Login");
    }

    private string GetSafeReturnUrl(string? returnUrl)
    {
        if (!string.IsNullOrWhiteSpace(returnUrl) && Url.IsLocalUrl(returnUrl))
        {
            return returnUrl;
        }

        return "/Admin";
    }

    private static bool PasswordsMatch(string provided, string expected)
    {
        var providedBytes = Encoding.UTF8.GetBytes(provided ?? string.Empty);
        var expectedBytes = Encoding.UTF8.GetBytes(expected ?? string.Empty);

        if (providedBytes.Length != expectedBytes.Length)
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(providedBytes, expectedBytes);
    }
}
