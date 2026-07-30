<?php

namespace Tests\Unit\Domains\Contact\ManageCalls\Api\Controllers;

use App\Models\Call;
use App\Models\Contact;
use App\Models\Vault;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactCallControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_gets_a_list_of_calls_of_a_contact(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $call = Call::factory()->create([
            'contact_id' => $contact->id,
            'description' => 'We discussed how much he loved Dwight.',
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/calls');

        $response->assertStatus(200);
        $response->assertJsonCount(1, 'data');
        $response->assertJsonPath('data.0.id', $call->id);
        $response->assertJsonPath('data.0.description', 'We discussed how much he loved Dwight.');
    }

    /** @test */
    public function it_logs_a_call(): void
    {
        $user = $this->createUser(['read', 'write']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $vault = $this->setPermissionInVault($user, Vault::PERMISSION_EDIT, $vault);

        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);

        $response = $this->post('/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/calls', [
            'called_at' => '2026-07-30',
            'description' => 'Talked about the wedding',
        ]);

        $response->assertStatus(201);
        $response->assertJsonPath('data.description', 'Talked about the wedding');

        $this->assertDatabaseHas('calls', [
            'contact_id' => $contact->id,
            'description' => 'Talked about the wedding',
        ]);
    }

    /** @test */
    public function it_gets_an_exception_listing_calls_of_another_account_vault(): void
    {
        $this->createUser(['read']);

        $vault = Vault::factory()->create();
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/calls');

        $response->assertResourceNotFound();
    }
}
