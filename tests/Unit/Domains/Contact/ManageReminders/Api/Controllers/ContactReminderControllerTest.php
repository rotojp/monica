<?php

namespace Tests\Unit\Domains\Contact\ManageReminders\Api\Controllers;

use App\Models\Contact;
use App\Models\ContactReminder;
use App\Models\Vault;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactReminderControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_gets_a_list_of_reminders_in_a_vault(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $reminder = ContactReminder::factory()->create([
            'contact_id' => $contact->id,
            'label' => 'Wish happy birthday',
        ]);

        // a reminder in another vault must not appear
        ContactReminder::factory()->create();

        $response = $this->get('/api/vaults/'.$vault->id.'/reminders');

        $response->assertStatus(200);
        $response->assertJsonCount(1, 'data');
        $response->assertJsonPath('data.0.id', $reminder->id);
        $response->assertJsonPath('data.0.label', 'Wish happy birthday');
        $response->assertJsonPath('data.0.contact.id', $contact->id);
    }

    /** @test */
    public function it_gets_an_exception_listing_reminders_of_another_account_vault(): void
    {
        $this->createUser(['read']);

        $vault = Vault::factory()->create();

        $response = $this->get('/api/vaults/'.$vault->id.'/reminders');

        $response->assertResourceNotFound();
    }
}
